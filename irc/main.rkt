#lang racket/base

(require racket/async-channel)
(require racket/list)
(require racket/match)
(require racket/string)
(require racket/tcp)

(provide irc-get-connection
         irc-connection-in-channel
         irc-send-command
	 irc-send-message
	 irc-join-channel
	 irc-connect
	 irc-set-nick
	 irc-set-user-info
         (struct-out irc-raw-message)
         (struct-out irc-message))

(struct irc-connection (in-port out-port in-channel))

;; IRC message types
;; * irc-raw-message
;;   * irc-unparsable-message
;;   * irc-message
;;     * irc-channel-message
;;     * etc.

(struct irc-raw-message (content))
(struct irc-message irc-raw-message (prefix command parameters))

(define (irc-get-connection host port)
  (define-values (in out) (tcp-connect host port))
  (file-stream-buffer-mode out 'line)
  (define in-channel (make-async-channel))
  (define connection (irc-connection in out in-channel))

  (thread (lambda ()
            (let loop ()
              (define line (read-line in))
              (unless (eof-object? line)
                (define message (parse-message line))
                (match message
                  [(irc-message _ _ "PING" params)
                   (irc-send-command connection "PONG" "pongresponse")]
                  [_ (async-channel-put in-channel message)])
                (loop)))))
  connection)

(define (irc-send-command connection command . parameters)
  (fprintf (irc-connection-out-port connection)
           "~a ~a\r\n"
           command
           (string-join parameters)))

(define (irc-set-nick connection nick)
  (irc-send-command connection "NICK" nick))

(define (irc-set-user-info connection nick real-name)
  (irc-send-command connection
		    "USER"
		    nick
		    "0"
		    "*"
		    (string-append ":" real-name)))

(define (irc-connect server port nick real-name)
  (define connection (irc-get-connection server port))
  (irc-set-nick connection nick)
  (irc-set-user-info connection nick real-name)
  connection)

(define (irc-join-channel connection channel)
  (irc-send-command connection "JOIN" channel))

(define (irc-send-message connection target message)
  (irc-send-command connection
		    "PRIVMSG"
		    target
		    (string-append ":" message)))

;; Given the string of an IRC message, returns an irc-raw-message that has been parsed as far as possible
(define (parse-message message)
  (define parts (string-split message))
  (define prefix (if (and (pair? parts)
                          (string-starts-with? (list-ref parts 0) ":"))
                     (substring (list-ref parts 0) 1)
                     #f))
  (cond [(> (length parts) (if prefix 1 0))
         (define command (list-ref parts (if prefix 1 0)))
         (define param-parts (list-tail parts (if prefix 2 1)))
         (irc-message message prefix command (parse-params param-parts))]
        [else #f]))

;; Given the list of param parts, return the list of params
(define (parse-params parts)
  (define first-tail-part (find-first-tail-part parts))
  (cond [first-tail-part
         (define tail-with-colon (string-join (list-tail parts first-tail-part)))
         (define tail-param (if (string-starts-with? tail-with-colon ":")
                                (substring tail-with-colon 1)
                                tail-with-colon))
         (append (take parts first-tail-part)
                 (list tail-param))]
        [else parts]))

;; Return the index of the first part that starts the tail parameters; of #f if no tail exists
(define (find-first-tail-part param-parts)
  (define first-colon-index (memf/index (lambda (v) (string-starts-with? v ":"))
                                        param-parts))
  (cond [(or first-colon-index (> (length param-parts) 14))
         (min 14 (if first-colon-index first-colon-index 14))]
        [else #f]))

;; Like memf, but returns the index of the first item to satisfy proc instead of
;; the list starting at that item.
(define (memf/index proc lst)
  (define memf-result (memf proc lst))
  (cond [memf-result (- (length lst) (length memf-result))]
        [else #f]))

(define (string-starts-with? s1 s2)
  (equal? (substring s1 0 (string-length s2))
          s2))