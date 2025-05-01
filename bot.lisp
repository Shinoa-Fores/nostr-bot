;;bot.lisp

(defpackage :nostr-bot
  (:use :cl :websocket-driver :yason :bip0340 :babel :uiop)
  (:shadowing-import-from :uiop :with-output)
  (:import-from :str :empty? :trim :split)
  (:shadowing-import-from :str :emptyp)
  (:export :start-bot :process-command))

(in-package :nostr-bot)

;; Configuration
(defparameter *bot-pubkey* nil
  "Bot's hex public key loaded from ~/.config/n/nostr.conf")
(defparameter *bot-privkey* nil
  "Bot's hex private key loaded from ~/.config/n/nostr.conf")
(defparameter *owner-pubkey* nil
  "Owner's hex public key loaded from ~/.config/n/nostr.conf for eval command")
(defparameter *relay-url* "wss://relay.nostr.band"
  "Nostr relay WebSocket URL")
(defparameter *processed-events* (make-hash-table :test #'equal)
  "Cache of processed event IDs to prevent duplicate responses")
(defparameter *sent-event-ids* (make-hash-table :test #'equal)
  "Cache of event IDs sent by the bot for debugging")

;; Load BOTPUBKEY, BOTPRIVKEY, and PUBKEY from ~/.config/n/nostr.conf
(defun load-config ()
  (let ((config-file (merge-pathnames ".config/n/nostr.conf" (user-homedir-pathname))))
    (format t "[INFO] Loading config from ~a~%" config-file)
    (unless (probe-file config-file)
      (error "[ERROR] Config file not found: ~a" config-file))
    (with-open-file (stream config-file :direction :input)
      (loop for line = (read-line stream nil nil)
            while line
            do (let ((trimmed-line (trim line)))
                 (cond
                   ((search "BOTPUBKEY=" trimmed-line :test #'string-equal)
                    (setf *bot-pubkey* (trim (subseq trimmed-line (length "BOTPUBKEY=")))))
                   ((search "BOTPRIVKEY=" trimmed-line :test #'string-equal)
                    (setf *bot-privkey* (trim (subseq trimmed-line (length "BOTPRIVKEY=")))))
                   ((search "PUBKEY=" trimmed-line :test #'string-equal)
                    (setf *owner-pubkey* (trim (subseq trimmed-line (length "PUBKEY=")))))))))
    (unless *bot-pubkey*
      (error "[ERROR] BOTPUBKEY not found in ~a" config-file))
    (unless *bot-privkey*
      (error "[ERROR] BOTPRIVKEY not found in ~a" config-file))
    (unless *owner-pubkey*
      (error "[ERROR] PUBKEY not found in ~a" config-file))
    (unless (and (= (length *bot-pubkey*) 64)
                 (every (lambda (c) (or (digit-char-p c 16) (error "Invalid hex in BOTPUBKEY")))
                        *bot-pubkey*))
      (error "[ERROR] BOTPUBKEY is not a valid 64-char hex string"))
    (unless (and (= (length *owner-pubkey*) 64)
                 (every (lambda (c) (or (digit-char-p c 16) (error "Invalid hex in PUBKEY")))
                        *owner-pubkey*))
      (error "[ERROR] PUBKEY is not a valid 64-char hex string"))
    (format t "[INFO] Loaded BOTPUBKEY: ~a~%" *bot-pubkey*)
    (format t "[INFO] Loaded BOTPRIVKEY: ~a...~%" (subseq *bot-privkey* 0 (min 8 (length *bot-privkey*))))
    (format t "[INFO] Loaded PUBKEY: ~a~%" *owner-pubkey*)))

(defun hex-string-to-byte-array (hex)
  "Convert a hex string to a byte array."
  (let* ((len (length hex))
         (bytes (make-array (/ len 2) :element-type '(unsigned-byte 8))))
    (loop for i from 0 below len by 2
          for j from 0
          do (setf (aref bytes j)
                   (parse-integer (subseq hex i (+ i 2)) :radix 16)))
    bytes))

(defun byte-array-to-hex-string (bytes)
  "Convert a byte array to a lowercase hex string."
  (string-downcase
   (with-output-to-string (s)
     (loop for byte across bytes
           do (format s "~2,'0x" byte)))))

(defun serialize-event-for-id (event)
  "Serialize event data structure for ID hashing per Nostr spec."
  (format t "[DEBUG] Serializing event for ID~%")
  (format t "[DEBUG] Tags: ~a~%" (getf event :tags))
  (with-output-to-string (s)
    (format s "[0,\"~a\",~a,~a," *bot-pubkey* (getf event :created_at) (getf event :kind))
    (yason:encode (getf event :tags) s)
    (format s ",")
    (yason:encode (getf event :content) s)
    (format s "]")))

(defun compute-event-id (serialized)
  "Compute SHA-256 hash of serialized event."
  (format t "[DEBUG] Computing event ID~%")
  (format t "[DEBUG] Serialized string: ~a~%" serialized)
  (let ((digest (ironclad:make-digest :sha256)))
    (ironclad:update-digest digest (babel:string-to-octets serialized :encoding :utf-8))
    (byte-array-to-hex-string (ironclad:produce-digest digest))))

(defun verify-event-id (event-hash)
  "Verify the event ID matches the serialized event."
  (let* ((serialized (with-output-to-string (s)
                       (format s "[0,\"~a\",~a,~a," (gethash "pubkey" event-hash)
                               (gethash "created_at" event-hash)
                               (gethash "kind" event-hash))
                       (yason:encode (gethash "tags" event-hash) s)
                       (format s ",")
                       (yason:encode (gethash "content" event-hash) s)
                       (format s "]")))
         (computed-id (compute-event-id serialized)))
    (format t "[DEBUG] Verifying event ID~%")
    (format t "[DEBUG] Serialized for verification: ~a~%" serialized)
    (format t "[DEBUG] Computed ID: ~a~%" computed-id)
    (format t "[DEBUG] Provided ID: ~a~%" (gethash "id" event-hash))
    (string-equal computed-id (gethash "id" event-hash))))

(defun sign-event (event-id privkey pubkey)
  "Sign event ID with private key using bip0340."
  (handler-case
      (let* ((event-id-bytes (hex-string-to-byte-array event-id))
             (privkey-bytes (hex-string-to-byte-array privkey))
             (pubkey-bytes (hex-string-to-byte-array pubkey))
             (computed-pubkey (byte-array-to-hex-string (public-key privkey-bytes))))
        (format t "[DEBUG] Signing id=~a with privkey=~a~%"
                (subseq event-id 0 8)
                (subseq privkey 0 8))
        (unless (string-equal computed-pubkey pubkey)
          (error "Private key does not match public key: expected ~a, got ~a" pubkey computed-pubkey))
        (let* ((sig (sign-message privkey-bytes event-id-bytes))
               (sig-hex (byte-array-to-hex-string sig))
               (verified (verify-signature pubkey-bytes event-id-bytes sig)))
          (format t "[DEBUG] Signature generated: ~a~%" sig-hex)
          (format t "[DEBUG] Signature verification: ~a~%" verified)
          (unless verified
            (error "Signature failed verification"))
          sig-hex))
    (error (e)
      (format t "[ERROR] Signing failed: ~a~%" e)
      (error "Failed to sign event: ~a" e))))

;; Send response event
(defun send-response (client sender-pubkey content event-id)
  (let* ((clean-content (trim content))
         (event-plist (list :created_at (- (get-universal-time) 2208988800)
                            :kind 1
                            :tags (list (list "p" sender-pubkey)
                                        (list "e" event-id *relay-url* "reply"))
                            :content clean-content))
         (serialized (serialize-event-for-id event-plist))
         (event-id (compute-event-id serialized))
         (signature (sign-event event-id *bot-privkey* *bot-pubkey*))
         (event-hash (make-hash-table :test #'equal)))
    (format t "[DEBUG] Response event: ~a~%" event-plist)
    (setf (gethash "id" event-hash) event-id
          (gethash "pubkey" event-hash) *bot-pubkey*
          (gethash "created_at" event-hash) (getf event-plist :created_at)
          (gethash "kind" event-hash) (getf event-plist :kind)
          (gethash "tags" event-hash) (getf event-plist :tags)
          (gethash "content" event-hash) clean-content
          (gethash "sig" event-hash) signature)
    (format t "[DEBUG] Verifying event ID before sending~%")
    (unless (verify-event-id event-hash)
      (error "[ERROR] Event ID verification failed"))
    (format t "[DEBUG] Serialized for ID: ~a~%" serialized)
    (format t "[DEBUG] Serialized for verification: ~a~%"
            (with-output-to-string (s)
              (format s "[0,\"~a\",~a,~a," (gethash "pubkey" event-hash)
                      (gethash "created_at" event-hash)
                      (gethash "kind" event-hash))
              (yason:encode (gethash "tags" event-hash) s)
              (format s ",")
              (yason:encode (gethash "content" event-hash) s)
              (format s "]")))
    (let ((message (with-output-to-string (s)
                     (let ((yason:*symbol-key-encoder* #'string-downcase))
                       (yason:encode (list "EVENT" event-hash) s)))))
      (format t "[INFO] Sending response: ~a~%" message)
      (wsd:send client message)
      (setf (gethash event-id *sent-event-ids*) t))))

;; Start the bot
(defun start-bot ()
  (handler-case
      (progn
        (format t "[INFO] Starting Nostr bot~%")
        (load-config)
        (unless *bot-pubkey*
          (error "[ERROR] Bot public key not loaded"))
        (unless *bot-privkey*
          (error "[ERROR] Bot private key not loaded"))
        (unless *owner-pubkey*
          (error "[ERROR] Owner public key not loaded"))
        (let ((client (wsd:make-client *relay-url*)))
          (wsd:on :open client
                  (lambda ()
                    (format t "[INFO] WebSocket connected to ~a~%" *relay-url*)))
          (wsd:on :error client
                  (lambda (error)
                    (format t "[ERROR] WebSocket error: ~a~%" error)))
          (wsd:on :close client
                  (lambda (&key code reason)
                    (format t "[INFO] WebSocket closed: code=~a, reason=~a~%" code reason)))
          (wsd:on :message client
                  (lambda (message)
                    (format t "[INFO] Raw message received: ~a~%" message)
                    (handler-case
                        (let* ((data (yason:parse message :object-as :alist))
                               (type (first data)))
                          (format t "[INFO] Parsed message type: ~a~%" type)
                          (format t "[DEBUG] Raw parsed data: ~a~%" data)
                          (cond
                            ((equal type "EVENT")
                             (let* ((event (third data))
                                    (id (cdr (assoc "id" event :test #'string=)))
                                    (content (cdr (assoc "content" event :test #'string=)))
                                    (tags (cdr (assoc "tags" event :test #'string=)))
                                    (kind (cdr (assoc "kind" event :test #'string=)))
                                    (pubkey (cdr (assoc "pubkey" event :test #'string=))))
                               (format t "[INFO] Event: id=~a, kind=~a, content=~a, tags=~a~%"
                                       id kind content tags)
                               (when (and (eql kind 1)
                                          (not (string-equal pubkey *bot-pubkey*))
                                          (not (gethash id *processed-events*))
                                          (find-if (lambda (tag)
                                                     (and (equal (first tag) "p")
                                                          (equal (second tag) *bot-pubkey*)))
                                                   tags))
                                 (format t "[INFO] Message found!~%")
                                 (setf (gethash id *processed-events*) t)
                                 (let ((response (process-command content pubkey)))
                                   (when response
                                     (send-response client pubkey response id))))))
                            ((equal type "OK")
                             (let* ((event-id (second data))
                                    (success (third data))
                                    (message (fourth data)))
                               (format t "[INFO] OK: event=~a, success=~a, message=~a~%"
                                       event-id success message)
                               (unless success
                                 (format t "[ERROR] Event rejected by relay: ~a~%" message)
                                 (remhash event-id *sent-event-ids*)
                                 (remhash event-id *processed-events*))))
                            ((equal type "NOTICE")
                             (format t "[INFO] Notice: ~a~%" (second data)))
                            ((equal type "EOSE")
                             (format t "[INFO] End of stored events for subscription: ~a~%" (second data)))
                            (t
                             (format t "[INFO] Unknown message type: ~a~%" type))))
                      (error (e)
                        (format t "[ERROR] JSON parse error: ~a~%" e)))))
          (format t "[INFO] Starting WebSocket connection~%")
          (wsd:start-connection client)
          (unwind-protect
               (progn
                 (let* ((since (- (get-universal-time) 2208988800 300))
                        (subscription-hash (make-hash-table :test #'equal))
                        (subscription (progn
                                        (setf (gethash "kinds" subscription-hash) (list 1))
                                        (setf (gethash "#p" subscription-hash) (list *bot-pubkey*))
                                        (setf (gethash "since" subscription-hash) since)
                                        (with-output-to-string (s)
                                          (yason:encode
                                           (list "REQ" "mentions" subscription-hash)
                                           s)))))
                   (format t "[INFO] Sending subscription: ~a~%" subscription)
                   (format t "[INFO] Since timestamp: ~a~%" since)
                   (wsd:send client subscription))
                 (format t "[INFO] Bot running. Press Ctrl+C to stop.~%")
                 (loop (sleep 20)))
            (format t "[INFO] Closing WebSocket connection~%")
            (wsd:close-connection client))))
    (error (e)
      (format t "[ERROR] Bot failed: ~a~%" e))
    #+sbcl
    (sb-sys:interactive-interrupt ()
      (format t "[INFO] Caught Ctrl+C, shutting down...~%")
      (return-from start-bot))
    #-sbcl
    (error (e)
      (format t "[INFO] Interrupt handling not supported; bot failed: ~a~%" e)
      (return-from start-bot))))
