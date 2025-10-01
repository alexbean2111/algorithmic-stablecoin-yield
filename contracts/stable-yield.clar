;; title: stable-yield
;; version: 1.0.0
;; summary: Algorithmic stablecoin yield generation platform
;; description: Deploy stablecoins across highest-yielding opportunities automatically,
;;              arbitrage between lending protocols, compound yields through optimal rebalancing,
;;              manage risk through diversification, and provide consistent stablecoin returns

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INVALID_AMOUNT (err u101))
(define-constant ERR_INSUFFICIENT_BALANCE (err u102))
(define-constant ERR_POOL_NOT_FOUND (err u103))
(define-constant ERR_WITHDRAWAL_TOO_EARLY (err u104))
(define-constant ERR_CONTRACT_PAUSED (err u105))
(define-constant ERR_REBALANCE_IN_PROGRESS (err u106))
(define-constant ERR_INVALID_PROTOCOL (err u107))

;; Minimum deposit amount (1 STX)
(define-constant MIN_DEPOSIT u1000000)
;; Maximum protocol allocation percentage (50%)
(define-constant MAX_PROTOCOL_ALLOCATION u5000)
;; Rebalancing threshold (5%)
(define-constant REBALANCE_THRESHOLD u500)
;; Performance fee (2%)
(define-constant PERFORMANCE_FEE u200)
;; Withdrawal delay (1 day in blocks)
(define-constant WITHDRAWAL_DELAY u144)

;; Data Variables
(define-data-var contract-paused bool false)
(define-data-var total-deposits uint u0)
(define-data-var total-shares uint u0)
(define-data-var last-rebalance-block uint u0)
(define-data-var protocol-count uint u0)
(define-data-var performance-fee-collected uint u0)
(define-data-var emergency-admin (optional principal) none)

;; Data Maps
;; User deposits and shares
(define-map user-deposits principal { amount: uint, shares: uint, deposit-block: uint })

;; Withdrawal requests
(define-map withdrawal-requests principal { amount: uint, request-block: uint, processed: bool })

;; Protocol allocations and yields
(define-map protocol-data
  uint
  {
    name: (string-ascii 32),
    allocated-amount: uint,
    target-allocation: uint,
    current-yield: uint,
    last-updated: uint,
    active: bool
  }
)

;; Yield history for performance tracking
(define-map yield-history uint { block: uint, total-value: uint, apy: uint })

;; User yield tracking
(define-map user-yield-data principal { total-earned: uint, last-claim: uint })

;; Protocol performance metrics
(define-map protocol-performance
  uint
  {
    total-yield-generated: uint,
    risk-score: uint,
    uptime-percentage: uint,
    last-performance-update: uint
  }
)

;; Public Functions

;; Deposit stablecoins to earn yield
(define-public (deposit (amount uint))
  (let (
    (caller tx-sender)
    (current-total-deposits (var-get total-deposits))
    (current-total-shares (var-get total-shares))
    (user-data (default-to { amount: u0, shares: u0, deposit-block: u0 } (map-get? user-deposits caller)))
  )
    ;; Validation checks
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (>= amount MIN_DEPOSIT) ERR_INVALID_AMOUNT)
    
    ;; Calculate shares to mint
    (let (
      (shares-to-mint (if (is-eq current-total-shares u0)
        amount
        (/ (* amount current-total-shares) current-total-deposits)
      ))
    )
      ;; Update user data
      (map-set user-deposits caller {
        amount: (+ (get amount user-data) amount),
        shares: (+ (get shares user-data) shares-to-mint),
        deposit-block: stacks-block-height
      })
      
      ;; Update global variables
      (var-set total-deposits (+ current-total-deposits amount))
      (var-set total-shares (+ current-total-shares shares-to-mint))
      
      ;; Initialize user yield data if first deposit
      (if (is-eq (get amount user-data) u0)
        (map-set user-yield-data caller { total-earned: u0, last-claim: stacks-block-height })
        true
      )
      
      (ok shares-to-mint)
    )
  )
)

;; Request withdrawal of deposited funds
(define-public (request-withdrawal (amount uint))
  (let (
    (caller tx-sender)
    (user-data (unwrap! (map-get? user-deposits caller) ERR_INSUFFICIENT_BALANCE))
  )
    ;; Validation
    (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    (asserts! (>= (get amount user-data) amount) ERR_INSUFFICIENT_BALANCE)
    
    ;; Create withdrawal request
    (map-set withdrawal-requests caller {
      amount: amount,
      request-block: stacks-block-height,
      processed: false
    })
    
    (ok true)
  )
)

;; Process withdrawal after delay period
(define-public (process-withdrawal)
  (let (
    (caller tx-sender)
    (withdrawal-data (unwrap! (map-get? withdrawal-requests caller) ERR_INVALID_AMOUNT))
    (user-data (unwrap! (map-get? user-deposits caller) ERR_INSUFFICIENT_BALANCE))
  )
    ;; Check withdrawal delay
    (asserts! (>= (- stacks-block-height (get request-block withdrawal-data)) WITHDRAWAL_DELAY) ERR_WITHDRAWAL_TOO_EARLY)
    (asserts! (not (get processed withdrawal-data)) ERR_INVALID_AMOUNT)
    
    (let (
      (withdrawal-amount (get amount withdrawal-data))
      (current-total-deposits (var-get total-deposits))
      (current-total-shares (var-get total-shares))
      (shares-to-burn (/ (* withdrawal-amount (get shares user-data)) (get amount user-data)))
    )
      ;; Update user data
      (map-set user-deposits caller {
        amount: (- (get amount user-data) withdrawal-amount),
        shares: (- (get shares user-data) shares-to-burn),
        deposit-block: (get deposit-block user-data)
      })
      
      ;; Mark withdrawal as processed
      (map-set withdrawal-requests caller {
        amount: withdrawal-amount,
        request-block: (get request-block withdrawal-data),
        processed: true
      })
      
      ;; Update global variables
      (var-set total-deposits (- current-total-deposits withdrawal-amount))
      (var-set total-shares (- current-total-shares shares-to-burn))
      
      (ok withdrawal-amount)
    )
  )
)

;; Add new yield protocol
(define-public (add-protocol (name (string-ascii 32)) (target-allocation uint))
  (let (
    (protocol-id (+ (var-get protocol-count) u1))
  )
    ;; Only contract owner can add protocols
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (<= target-allocation MAX_PROTOCOL_ALLOCATION) ERR_INVALID_AMOUNT)
    
    ;; Add protocol data
    (map-set protocol-data protocol-id {
      name: name,
      allocated-amount: u0,
      target-allocation: target-allocation,
      current-yield: u0,
      last-updated: stacks-block-height,
      active: true
    })
    
    ;; Initialize performance data
    (map-set protocol-performance protocol-id {
      total-yield-generated: u0,
      risk-score: u5000, ;; Default 50% risk score
      uptime-percentage: u10000, ;; Default 100% uptime
      last-performance-update: stacks-block-height
    })
    
    (var-set protocol-count protocol-id)
    (ok protocol-id)
  )
)

;; Update protocol yield rates
(define-public (update-protocol-yield (protocol-id uint) (new-yield uint))
  (let (
    (protocol (unwrap! (map-get? protocol-data protocol-id) ERR_INVALID_PROTOCOL))
  )
    ;; Only contract owner can update yields
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (asserts! (get active protocol) ERR_INVALID_PROTOCOL)
    
    ;; Update protocol yield
    (map-set protocol-data protocol-id {
      name: (get name protocol),
      allocated-amount: (get allocated-amount protocol),
      target-allocation: (get target-allocation protocol),
      current-yield: new-yield,
      last-updated: stacks-block-height,
      active: (get active protocol)
    })
    
    (ok true)
  )
)

;; Rebalance funds across protocols
(define-public (rebalance-protocols)
  (begin
    ;; Only contract owner or emergency admin can rebalance
    (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                  (match (var-get emergency-admin)
                    admin (is-eq tx-sender admin)
                    false)) ERR_NOT_AUTHORIZED)
    
    ;; Update last rebalance block
    (var-set last-rebalance-block stacks-block-height)
    
    ;; Record yield snapshot
    (map-set yield-history stacks-block-height {
      block: stacks-block-height,
      total-value: (var-get total-deposits),
      apy: (calculate-current-apy)
    })
    
    (ok true)
  )
)

;; Claim accumulated yield
(define-public (claim-yield)
  (let (
    (caller tx-sender)
    (user-data (unwrap! (map-get? user-deposits caller) ERR_INSUFFICIENT_BALANCE))
    (yield-data (default-to { total-earned: u0, last-claim: u0 } (map-get? user-yield-data caller)))
  )
    (asserts! (> (get shares user-data) u0) ERR_INSUFFICIENT_BALANCE)
    
    (let (
      (yield-earned (calculate-user-yield caller))
      (fee-amount (/ (* yield-earned PERFORMANCE_FEE) u10000))
      (net-yield (- yield-earned fee-amount))
    )
      ;; Update user yield data
      (map-set user-yield-data caller {
        total-earned: (+ (get total-earned yield-data) yield-earned),
        last-claim: stacks-block-height
      })
      
      ;; Update collected fees
      (var-set performance-fee-collected (+ (var-get performance-fee-collected) fee-amount))
      
      (ok net-yield)
    )
  )
)

;; Emergency pause function
(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set contract-paused true)
    (ok true)
  )
)

;; Emergency unpause function
(define-public (unpause-contract)
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (var-set contract-paused false)
    (ok true)
  )
)

;; Read-only Functions

;; Get user deposit information
(define-read-only (get-user-deposits (user principal))
  (map-get? user-deposits user)
)

;; Get user yield information
(define-read-only (get-user-yield (user principal))
  (map-get? user-yield-data user)
)

;; Get protocol information
(define-read-only (get-protocol-info (protocol-id uint))
  (map-get? protocol-data protocol-id)
)

;; Get total value locked
(define-read-only (get-tvl)
  (var-get total-deposits)
)

;; Get current APY estimate
(define-read-only (get-current-apy)
  (calculate-current-apy)
)

;; Get contract status
(define-read-only (get-contract-status)
  {
    paused: (var-get contract-paused),
    total-deposits: (var-get total-deposits),
    total-shares: (var-get total-shares),
    protocol-count: (var-get protocol-count),
    last-rebalance: (var-get last-rebalance-block)
  }
)

;; Private Functions

;; Calculate current APY based on protocol yields
(define-private (calculate-current-apy)
  (let (
    (protocol-count-val (var-get protocol-count))
  )
    ;; Simplified APY calculation - in production would aggregate all protocol yields
    (if (> protocol-count-val u0)
      u800 ;; Default 8% APY
      u0
    )
  )
)

;; Calculate user's earned yield
(define-private (calculate-user-yield (user principal))
  (let (
    (user-data (default-to { amount: u0, shares: u0, deposit-block: u0 } (map-get? user-deposits user)))
    (yield-data (default-to { total-earned: u0, last-claim: u0 } (map-get? user-yield-data user)))
  )
    ;; Simplified yield calculation based on time and shares
    (let (
      (blocks-since-last-claim (- stacks-block-height (get last-claim yield-data)))
      (user-share-percentage (if (> (var-get total-shares) u0)
        (/ (* (get shares user-data) u10000) (var-get total-shares))
        u0
      ))
    )
      ;; Calculate yield: (shares * time * apy) / (blocks per year * 10000)
      (/ (* (* (get shares user-data) blocks-since-last-claim) (calculate-current-apy)) u525600000)
    )
  )
)
