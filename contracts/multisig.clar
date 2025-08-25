;; multisig.clar - multisignature wallet for STX transfers
;; - Bootstrap with owner list & thresho            (emit-event (concat "revoked: id=" (int-to-utf8 id))) (called once)
;; - Propose: create transfer proposal
;; - Approve/Revoke: owners vote
;; - Execute: once approvals >= threshold, send STX to target

(define-constant ERR_NOT_OWNER u100)
(define-constant ERR_PROPOSAL_NOT_FOUND u101)
(define-constant ERR_ALREADY_EXECUTED u102)
(define-constant ERR_NOT_APPROVED u103)
(define-constant ERR_BAD_THRESHOLD u104)
(define-constant ERR_NO_FUNDS u105)
(define-constant ERR_ALREADY_APPROVED u106)
(define-constant ERR_NOT_BOOTSTRAPPED u107)

(define-data-var bootstrap-done bool false)
(define-data-var threshold uint u0)
(define-data-var owners (list 10 principal) (list)) ;; small fixed max: change as needed
(define-data-var proposal-counter uint u0)

;; Error codes
(define-constant ERR_INVALID_ID u108)

;; proposals map: id -> { proposer, to, amount, executed bool }
(define-map proposals 
    {id: uint} 
    {proposer: principal, to: principal, amount: uint, executed: bool})

;; approvals: (id, owner) -> bool
(define-map approvals 
    {id: uint, owner: principal} 
    {approved: bool})

;; Events
(define-data-var last-event (string-ascii 500) "")

(define-private (emit-event (e (string-ascii 500)))
  (var-set last-event e))

(define-private (check-id (id uint))
  (and (>= id u1) (<= id (var-get proposal-counter))))

;; Bootstrap: set owners & threshold once
(define-public (bootstrap (owner-list (list 10 principal)) (thresh uint))
  (begin
    (asserts! (not (var-get bootstrap-done)) (err ERR_BAD_THRESHOLD))
    (asserts! (> (len owner-list) u0) (err ERR_BAD_THRESHOLD))
    (asserts! (> thresh u0) (err ERR_BAD_THRESHOLD))
    (asserts! (<= thresh (len owner-list)) (err ERR_BAD_THRESHOLD))
    (var-set owners owner-list)
    (var-set threshold thresh)
    (var-set bootstrap-done true)
    (emit-event (concat "bootstrap: threshold=" (int-to-ascii thresh)))
    (ok true)))

(define-read-only (is-owner (who principal))
  (is-some (index-of? (var-get owners) who)))

;; Propose a transfer: proposer is any owner
(define-public (propose (to principal) (amount uint))
  (begin
    (asserts! (var-get bootstrap-done) (err ERR_NOT_BOOTSTRAPPED))
    (asserts! (is-owner tx-sender) (err ERR_NOT_OWNER))
    (asserts! (> amount u0) (err ERR_BAD_THRESHOLD))
    (let 
      ((id (+ (var-get proposal-counter) u1))
       (new-proposal {proposer: tx-sender, to: to, amount: amount, executed: false}))
      (var-set proposal-counter id)
      (map-set proposals {id: id} new-proposal)
      (emit-event (concat (concat "proposed: id=" (int-to-ascii id))
                               (concat " amount=" (int-to-ascii amount))))
      (ok id))))

;; Approve
(define-public (approve (id uint))
  (begin
    (asserts! (var-get bootstrap-done) (err ERR_NOT_BOOTSTRAPPED))
    (asserts! (check-id id) (err ERR_INVALID_ID))
    (let ((p (map-get? proposals {id: id})))
      (asserts! (is-some p) (err ERR_PROPOSAL_NOT_FOUND))
      (asserts! (is-owner tx-sender) (err ERR_NOT_OWNER))
      (let ((rec (unwrap-panic p)))
        (asserts! (not (get executed rec)) (err ERR_ALREADY_EXECUTED))
        (match (map-get? approvals {id: id, owner: tx-sender})
          prev-approval (if (get approved prev-approval)
                          (err ERR_ALREADY_APPROVED)
                          (begin
                            (map-set approvals {id: id, owner: tx-sender} {approved: true})
                            (emit-event (concat "approved: id=" (int-to-ascii id)))
                            (ok true)))
          (begin
            (map-set approvals {id: id, owner: tx-sender} {approved: true})
            (emit-event (concat "approved: id=" (int-to-ascii id)))
            (ok true)))))))

;; Revoke approval
(define-public (revoke (id uint))
  (begin
    (asserts! (var-get bootstrap-done) (err ERR_NOT_BOOTSTRAPPED))
    (asserts! (check-id id) (err ERR_INVALID_ID))
    (let ((p (map-get? proposals {id: id})))
      (asserts! (is-some p) (err ERR_PROPOSAL_NOT_FOUND))
      (asserts! (is-owner tx-sender) (err ERR_NOT_OWNER))
      (let ((rec (unwrap-panic p)))
        (asserts! (not (get executed rec)) (err ERR_ALREADY_EXECUTED))
        (map-delete approvals {id: id, owner: tx-sender})
        (emit-event (concat "revoked: id=" (int-to-ascii id)))
        (ok true)))))

;; Count approvals for a proposal
(define-private (has-approved (owner principal) (id uint))
  (default-to false (get approved (map-get? approvals {id: id, owner: owner}))))

(define-read-only (count-approvals (id uint))
  (fold add-if-approved
        (var-get owners)
        u0))

(define-private (add-if-approved (owner principal) (acc uint))
  (if (has-approved owner (var-get proposal-counter))
      (+ acc u1)
      acc))

;; Execute: any caller can execute once approvals >= threshold and sufficient STX in contract
(define-public (execute (id uint))
  (begin
    (asserts! (var-get bootstrap-done) (err ERR_NOT_BOOTSTRAPPED))
    (let ((p (map-get? proposals {id: id})))
      (asserts! (is-some p) (err ERR_PROPOSAL_NOT_FOUND))
      (let ((rec (unwrap-panic p))
            (cnt (count-approvals id)))
        (asserts! (not (get executed rec)) (err ERR_ALREADY_EXECUTED))
        (asserts! (>= cnt (var-get threshold)) (err ERR_NOT_APPROVED))
        (let ((amt (get amount rec)) 
              (to (get to rec)))
          (asserts! (>= (stx-get-balance (as-contract tx-sender)) amt) (err ERR_NO_FUNDS))
          ;; mark executed first (checks-effects-interactions)
          (map-set proposals 
            {id: id} 
            {proposer: (get proposer rec), to: to, amount: amt, executed: true})
          (emit-event (concat (concat "executed: id=" (int-to-ascii id))
                                 (concat " amount=" (int-to-ascii amt))))
          (as-contract (stx-transfer? amt tx-sender to)))))))
