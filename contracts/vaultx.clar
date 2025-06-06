;;
;; Title: VaultX Protocol - Decentralized Multi-Collateral Stablecoin Platform
;;
;; Summary: A sophisticated DeFi protocol enabling users to mint USDx stablecoins
;;          by depositing STX and xBTC as collateral, featuring automated liquidation
;;          mechanisms and oracle-based price feeds for maximum stability.
;;
;; Description: VaultX revolutionizes the Bitcoin ecosystem by creating a robust
;;              collateralized debt position (CDP) system. Users can create vaults,
;;              deposit multiple asset types as collateral, and mint USDx tokens
;;              while maintaining full decentralization. The protocol features:
;;              - Multi-asset collateral support (STX + xBTC)
;;              - Real-time oracle price feeds with staleness protection
;;              - Automated liquidation engine with configurable thresholds
;;              - SIP-010 compliant USDx stablecoin implementation
;;              - Comprehensive vault management and monitoring tools
;;              - Emergency shutdown mechanisms for protocol security
;;

;; CONSTANTS

(define-constant CONTRACT-OWNER tx-sender)

;; Error Codes
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-VAULT-NOT-FOUND (err u1001))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u1002))
(define-constant ERR-VAULT-UNDERCOLLATERALIZED (err u1003))
(define-constant ERR-LIQUIDATION-NOT-ALLOWED (err u1004))
(define-constant ERR-INVALID-AMOUNT (err u1005))
(define-constant ERR-ORACLE-PRICE-STALE (err u1006))
(define-constant ERR-MINIMUM-COLLATERAL-RATIO (err u1007))
(define-constant ERR-VAULT-ALREADY-EXISTS (err u1008))
(define-constant ERR-INSUFFICIENT-USDX-BALANCE (err u1009))
(define-constant ERR-TRANSFER-FAILED (err u1010))

;; Protocol Parameters
(define-constant LIQUIDATION-RATIO u150) ;; 150% - liquidation threshold
(define-constant MINIMUM-COLLATERAL-RATIO u200) ;; 200% - minimum for new vaults
(define-constant LIQUIDATION-PENALTY u110) ;; 10% liquidation penalty
(define-constant STABILITY-FEE-RATE u2) ;; 2% annual stability fee
(define-constant MAX-PRICE-AGE u3600) ;; 1 hour max price age (in seconds)

;; DATA STRUCTURES

;; Vault Structure 
(define-map vaults
  { vault-id: uint }
  {
    owner: principal,
    stx-collateral: uint,
    xbtc-collateral: uint,
    debt: uint,
    last-update: uint,
    is-active: bool,
  }
)

;; User Vault Mapping
(define-map user-vaults
  { user: principal }
  { vault-ids: (list 10 uint) }
)

;; Oracle Price Feed Structure   
(define-map price-feeds
  { asset: (string-ascii 10) }
  {
    price: uint,
    timestamp: uint,
    confidence: uint,
  }
)

;; Protocol Statistics  
(define-data-var total-vaults uint u0)
(define-data-var total-debt uint u0)
(define-data-var total-stx-collateral uint u0)
(define-data-var total-xbtc-collateral uint u0)
(define-data-var liquidation-pool uint u0)

;; Authorization Mappings
(define-map authorized-liquidators
  principal
  bool
)
(define-map oracle-operators
  principal
  bool
)

;; USDX TOKEN IMPLEMENTATION
;; (SIP-010 Standard)

(define-fungible-token usdx)

;;   Token Metadata    
(define-data-var token-name (string-ascii 32) "USDx Stablecoin")
(define-data-var token-symbol (string-ascii 10) "USDx")
(define-data-var token-uri (optional (string-utf8 256)) none)
(define-data-var token-decimals uint u6)

;; SIP-010 Standard Functions 

(define-read-only (get-name)
  (ok (var-get token-name))
)

(define-read-only (get-symbol)
  (ok (var-get token-symbol))
)

(define-read-only (get-decimals)
  (ok (var-get token-decimals))
)

(define-read-only (get-balance (who principal))
  (ok (ft-get-balance usdx who))
)

(define-read-only (get-total-supply)
  (ok (ft-get-supply usdx))
)

(define-read-only (get-token-uri)
  (ok (var-get token-uri))
)

(define-public (transfer
    (amount uint)
    (from principal)
    (to principal)
    (memo (optional (buff 34)))
  )
  (begin
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (or (is-eq from tx-sender) (is-eq from contract-caller))
      ERR-NOT-AUTHORIZED
    )
    (asserts! (not (is-eq from to)) ERR-INVALID-AMOUNT)
    (ft-transfer? usdx amount from to)
  )
)

;; ORACLE SYSTEM

;; Oracle Operator Management 

(define-public (set-oracle-operator
    (operator principal)
    (authorized bool)
  )
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-eq operator tx-sender)) ERR-INVALID-AMOUNT)
    (ok (map-set oracle-operators operator authorized))
  )
)

;; Price Feed Management   

(define-public (update-price
    (asset (string-ascii 10))
    (price uint)
    (confidence uint)
  )
  (begin
    (asserts! (default-to false (map-get? oracle-operators tx-sender))
      ERR-NOT-AUTHORIZED
    )
    (asserts! (> price u0) ERR-INVALID-AMOUNT)
    (asserts! (and (>= confidence u1) (<= confidence u100)) ERR-INVALID-AMOUNT)
    (asserts! (> (len asset) u0) ERR-INVALID-AMOUNT)
    (ok (map-set price-feeds { asset: asset } {
      price: price,
      timestamp: stacks-block-height,
      confidence: confidence,
    }))
  )
)

(define-read-only (get-price (asset (string-ascii 10)))
  (let ((price-data (map-get? price-feeds { asset: asset })))
    (match price-data
      feed (if (< (- stacks-block-height (get timestamp feed)) MAX-PRICE-AGE)
        (ok (get price feed))
        ERR-ORACLE-PRICE-STALE
      )
      ERR-ORACLE-PRICE-STALE
    )
  )
)

;; VAULT MANAGEMENT SYSTEM

;; ault Creation   

(define-public (create-vault
    (stx-amount uint)
    (xbtc-amount uint)
  )
  (let (
      (vault-id (+ (var-get total-vaults) u1))
      (stx-price (unwrap! (get-price "STX") ERR-ORACLE-PRICE-STALE))
      (xbtc-price (unwrap! (get-price "xBTC") ERR-ORACLE-PRICE-STALE))
      (total-collateral-value (+ (* stx-amount stx-price) (* xbtc-amount xbtc-price)))
      (user-vaults-list (default-to (list)
        (get vault-ids (map-get? user-vaults { user: tx-sender }))
      ))
    )
    (asserts! (> stx-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= xbtc-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (< vault-id u1000000) ERR-INVALID-AMOUNT)
    (asserts! (is-none (map-get? vaults { vault-id: vault-id }))
      ERR-VAULT-ALREADY-EXISTS
    )
    ;; Transfer collateral to contract
    (try! (stx-transfer? stx-amount tx-sender (as-contract tx-sender)))
    ;; Create vault
    (map-set vaults { vault-id: vault-id } {
      owner: tx-sender,
      stx-collateral: stx-amount,
      xbtc-collateral: xbtc-amount,
      debt: u0,
      last-update: stacks-block-height,
      is-active: true,
    })
    ;; Update user vault list
    (map-set user-vaults { user: tx-sender } { vault-ids: (unwrap! (as-max-len? (append user-vaults-list vault-id) u10)
      ERR-INVALID-AMOUNT
    ) }
    )
    ;; Update protocol statistics
    (var-set total-vaults vault-id)
    (var-set total-stx-collateral (+ (var-get total-stx-collateral) stx-amount))
    (var-set total-xbtc-collateral
      (+ (var-get total-xbtc-collateral) xbtc-amount)
    )
    (ok vault-id)
  )
)

;; Collateral Managemen

(define-public (add-collateral
    (vault-id uint)
    (stx-amount uint)
    (xbtc-amount uint)
  )
  (let ((vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND)))
    (asserts! (> vault-id u0) ERR-INVALID-AMOUNT)
    (asserts! (is-eq (get owner vault) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active vault) ERR-VAULT-NOT-FOUND)
    (asserts! (> stx-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= xbtc-amount u0) ERR-INVALID-AMOUNT)
    ;; Transfer additional collateral
    (try! (stx-transfer? stx-amount tx-sender (as-contract tx-sender)))
    ;; Update vault
    (map-set vaults { vault-id: vault-id }
      (merge vault {
        stx-collateral: (+ (get stx-collateral vault) stx-amount),
        xbtc-collateral: (+ (get xbtc-collateral vault) xbtc-amount),
        last-update: stacks-block-height,
      })
    )
    ;; Update protocol statistics
    (var-set total-stx-collateral (+ (var-get total-stx-collateral) stx-amount))
    (var-set total-xbtc-collateral
      (+ (var-get total-xbtc-collateral) xbtc-amount)
    )
    (ok true)
  )
)

(define-public (withdraw-collateral
    (vault-id uint)
    (stx-amount uint)
  )
  (let (
      (vault (unwrap! (map-get? vaults { vault-id: vault-id }) ERR-VAULT-NOT-FOUND))
      (stx-price (unwrap! (get-price "STX") ERR-ORACLE-PRICE-STALE))
      (xbtc-price (unwrap! (get-price "xBTC") ERR-ORACLE-PRICE-STALE))
      (remaining-stx (- (get stx-collateral vault) stx-amount))
      (remaining-collateral-value (+ (* remaining-stx stx-price) (* (get xbtc-collateral vault) xbtc-price)))
      (debt (get debt vault))
    )
    (asserts! (> vault-id u0) ERR-INVALID-AMOUNT)
    (asserts! (is-eq (get owner vault) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active vault) ERR-VAULT-NOT-FOUND)
    (asserts! (> stx-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= (get stx-collateral vault) stx-amount)
      ERR-INSUFFICIENT-COLLATERAL
    )
    ;; Check if withdrawal maintains minimum collateral ratio (if debt exists)
    (if (> debt u0)
      (asserts!
        (>= (/ (* remaining-collateral-value u100) debt) MINIMUM-COLLATERAL-RATIO)
        ERR-MINIMUM-COLLATERAL-RATIO
      )
      true
    )
    ;; Transfer collateral back to user
    (try! (as-contract (stx-transfer? stx-amount tx-sender (get owner vault))))
    ;; Update vault
    (map-set vaults { vault-id: vault-id }
      (merge vault {
        stx-collateral: remaining-stx,
        last-update: stacks-block-height,
      })
    )
    ;; Update protocol statistics
    (var-set total-stx-collateral (- (var-get total-stx-collateral) stx-amount))
    (ok true)
  )
)