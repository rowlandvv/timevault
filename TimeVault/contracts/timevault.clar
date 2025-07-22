;; Time Vault - Production-Ready STX Locking Contract
;; Allows users to lock STX tokens for specified periods and earn rewards

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-balance (err u101))
(define-constant err-invalid-amount (err u102))
(define-constant err-invalid-duration (err u103))
(define-constant err-vault-not-found (err u104))
(define-constant err-vault-locked (err u105))
(define-constant err-already-claimed (err u106))
(define-constant err-contract-paused (err u107))
(define-constant err-insufficient-rewards (err u108))
(define-constant err-unauthorized (err u109))

;; Minimum and maximum lock durations (in blocks)
(define-constant min-lock-blocks u144) ;; ~1 day (assuming 10 min blocks)
(define-constant max-lock-blocks u52560) ;; ~365 days

;; Reward rates (basis points per year)
(define-constant base-reward-rate u500) ;; 5% base APY
(define-constant bonus-rate-per-month u50) ;; 0.5% bonus per month locked

;; Data Variables
(define-data-var total-locked uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var reward-pool uint u0)
(define-data-var contract-paused bool false)
(define-data-var vault-nonce uint u0)

;; Data Maps
(define-map vaults 
    { owner: principal, vault-id: uint }
    {
        amount: uint,
        lock-start: uint,
        lock-end: uint,
        reward-rate: uint,
        claimed: bool,
        emergency-withdrawn: bool
    }
)

(define-map user-vault-ids principal (list 100 uint))

;; Read-only functions

(define-read-only (get-vault (owner principal) (vault-id uint))
    (map-get? vaults { owner: owner, vault-id: vault-id })
)

(define-read-only (get-user-vaults (user principal))
    (default-to (list) (map-get? user-vault-ids user))
)

(define-read-only (get-total-locked)
    (var-get total-locked)
)

(define-read-only (get-reward-pool)
    (var-get reward-pool)
)

(define-read-only (is-paused)
    (var-get contract-paused)
)

(define-read-only (calculate-reward-rate (lock-duration uint))
    (let (
        (months-locked (/ lock-duration u4320)) ;; ~30 days per month
        (bonus-rate (* months-locked bonus-rate-per-month))
        (total-rate (+ base-reward-rate bonus-rate))
    )
        (if (> total-rate u2000) u2000 total-rate) ;; Cap at 20% APY
    )
)

(define-read-only (calculate-rewards (amount uint) (lock-duration uint))
    (let (
        (reward-rate (calculate-reward-rate lock-duration))
        (annual-reward (/ (* amount reward-rate) u10000))
        (duration-in-years (/ lock-duration u52560))
    )
        (if (is-eq duration-in-years u0)
            (/ (* annual-reward lock-duration) u52560)
            (* annual-reward duration-in-years)
        )
    )
)

;; Public functions

(define-public (create-vault (amount uint) (lock-duration uint))
    (let (
        (vault-id (+ (var-get vault-nonce) u1))
        (lock-end (+ stacks-block-height lock-duration))
        (reward-rate (calculate-reward-rate lock-duration))
        (user-vaults (get-user-vaults tx-sender))
    )
        ;; Validation
        (asserts! (not (var-get contract-paused)) err-contract-paused)
        (asserts! (> amount u0) err-invalid-amount)
        (asserts! (>= lock-duration min-lock-blocks) err-invalid-duration)
        (asserts! (<= lock-duration max-lock-blocks) err-invalid-duration)
        
        ;; Transfer STX to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Create vault record
        (map-set vaults
            { owner: tx-sender, vault-id: vault-id }
            {
                amount: amount,
                lock-start: stacks-block-height,
                lock-end: lock-end,
                reward-rate: reward-rate,
                claimed: false,
                emergency-withdrawn: false
            }
        )
        
        ;; Update user vault list
        (map-set user-vault-ids 
            tx-sender 
            (unwrap! (as-max-len? (append user-vaults vault-id) u100) err-invalid-amount)
        )
        
        ;; Update global state
        (var-set vault-nonce vault-id)
        (var-set total-locked (+ (var-get total-locked) amount))
        
        (ok vault-id)
    )
)

(define-public (claim-vault (vault-id uint))
    (let (
        (vault (unwrap! (get-vault tx-sender vault-id) err-vault-not-found))
        (rewards (calculate-rewards (get amount vault) (- (get lock-end vault) (get lock-start vault))))
    )
        ;; Validation
        (asserts! (>= stacks-block-height (get lock-end vault)) err-vault-locked)
        (asserts! (not (get claimed vault)) err-already-claimed)
        (asserts! (not (get emergency-withdrawn vault)) err-already-claimed)
        (asserts! (>= (var-get reward-pool) rewards) err-insufficient-rewards)
        
        ;; Mark as claimed
        (map-set vaults
            { owner: tx-sender, vault-id: vault-id }
            (merge vault { claimed: true })
        )
        
        ;; Transfer principal + rewards
        (try! (as-contract (stx-transfer? (get amount vault) tx-sender tx-sender)))
        (if (> rewards u0)
            (try! (as-contract (stx-transfer? rewards tx-sender tx-sender)))
            false
        )
        
        ;; Update global state
        (var-set total-locked (- (var-get total-locked) (get amount vault)))
        (var-set reward-pool (- (var-get reward-pool) rewards))
        (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) rewards))
        
        (ok { amount: (get amount vault), rewards: rewards })
    )
)

(define-public (emergency-withdraw (vault-id uint))
    (let (
        (vault (unwrap! (get-vault tx-sender vault-id) err-vault-not-found))
        (penalty-rate u1000) ;; 10% penalty
        (penalty-amount (/ (* (get amount vault) penalty-rate) u10000))
        (withdraw-amount (- (get amount vault) penalty-amount))
    )
        ;; Validation
        (asserts! (not (get claimed vault)) err-already-claimed)
        (asserts! (not (get emergency-withdrawn vault)) err-already-claimed)
        
        ;; Mark as emergency withdrawn
        (map-set vaults
            { owner: tx-sender, vault-id: vault-id }
            (merge vault { emergency-withdrawn: true })
        )
        
        ;; Transfer reduced amount back to user
        (try! (as-contract (stx-transfer? withdraw-amount tx-sender tx-sender)))
        
        ;; Add penalty to reward pool
        (var-set reward-pool (+ (var-get reward-pool) penalty-amount))
        
        ;; Update global state
        (var-set total-locked (- (var-get total-locked) (get amount vault)))
        
        (ok { withdrawn: withdraw-amount, penalty: penalty-amount })
    )
)

;; Admin functions

(define-public (add-rewards (amount uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (var-set reward-pool (+ (var-get reward-pool) amount))
        (ok amount)
    )
)

(define-public (pause-contract)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set contract-paused true)
        (ok true)
    )
)

(define-public (unpause-contract)
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (var-set contract-paused false)
        (ok true)
    )
)

(define-public (withdraw-excess-rewards (amount uint))
    (let (
        (current-pool (var-get reward-pool))
    )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (> current-pool amount) err-insufficient-balance)
        (try! (as-contract (stx-transfer? amount tx-sender contract-owner)))
        (var-set reward-pool (- current-pool amount))
        (ok amount)
    )
)

;; Initialize contract
(begin
    (var-set vault-nonce u0)
    (var-set total-locked u0)
    (var-set reward-pool u0)
    (var-set contract-paused false)
)