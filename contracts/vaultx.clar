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