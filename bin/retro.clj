;; The data half of a retrospective (dev-kit #28, #55): the friction of one merged issue, from the friction
;; log the hooks write on this machine (claude/hooks/friction.sh) and from GitHub. Read-only.
;;
;;   kit retro <issue> [--repo R] [--messages]        (--now T for tests)
;;
;; The log is ${XDG_STATE_HOME:-~/.local/state}/dev-kit/friction/<YYYY-MM>.jsonl: one line per hook event, in
;; the order they happened. What happened to a tool call follows from the events around it (tested live, #55):
;;   window, yes         PreToolUse → PermissionRequest (same turn and input) → PostToolUse or PostToolUseFailure
;;   window, no or Esc   PreToolUse → PermissionRequest → no outcome
;;   refused             PermissionDenied (the classifier), HookDenied (dev-kit's hook), or no outcome in a
;;                       turn that ended with Stop (a deny rule)
;;   Esc                 a turn (prompt_id) with neither Stop nor StopFailure that another turn follows
;; A call belongs to the task its branch names (<n>-slug in the task's repository); a call naming none, to its
;; turn's task when the turn names exactly one. An owner's message, an Esc, a failed turn and a question to the
;; owner belong to the task the session was last working on.
;; The output holds counts, ask rules and command shapes: never commands, paths, URLs, flag values or the
;; owner's words, except the owner's marks («трение: …»).
(ns retro
  (:require
   [babashka.fs :as fs]
   [cheshire.core :as json]
   [clojure.java.io :as io]
   [clojure.string :as str])
  (:import
   (java.time Duration Instant OffsetDateTime)
   (java.util.regex Pattern)))


(defn fail!
  [& msg]
  (binding [*out* *err*]
    (println (str "kit: retro: " (str/join " " msg)))
    (flush))
  (System/exit 1))


;; ------------------------------------------------------------------ time


(defn parse-time
  "A time given on the command line, in UTC or with an offset."
  [opt s]
  (or (try (Instant/parse s) (catch Exception _ nil))
      (try (.toInstant (OffsetDateTime/parse s)) (catch Exception _ nil))
      (fail! opt s ": not a time; write it as 2026-11-12T10:00:00Z or 2026-11-12T11:00:00+01:00")))


(defn instant [s] (when s (Instant/parse s)))


(defn before? [^Instant a ^Instant b] (.isBefore a b))


(defn stamp [^Instant t] (str/replace (subs (str t) 0 16) "T" " "))


(defn span
  [a b]
  (let [m (.toMinutes (Duration/between a b))]
    (if (>= m 60)
      (format "%dh %02dm" (quot m 60) (rem m 60))
      (str m "m"))))


;; ------------------------------------------------------------------ commands
;; A shape names what a command was without its arguments ("gh pr view", "kit merge"): every
;; word a plain command word, never a path, a flag value or inline code. Segments are a command's simple
;; commands; ask rules match against them.


(def skip-words
  #{"cd" "export" "set" "unset" "echo" "printf" "sleep" "true" "false" ":" "for" "while" "until" "if" "local"
    "read" "trap" "wait" "exit" "return" "shift" "case" "esac" "done" "fi" "test" "["})


(def lead-words #{"do" "then" "else" "elif" "{" "(" "!" "time" "env" "command" "exec" "nohup"})


(def gh-value-flags
  #{"-R" "--repo" "-H" "--header" "-f" "-F" "--field" "--raw-field" "--jq" "-q" "-t" "--template" "--json" "-X"
    "--method" "--input" "-b" "--body" "--body-file" "-T" "--title" "-l" "--label" "-a" "--assignee" "-B" "--base"
    "--head" "-s" "--state" "-L" "--limit" "--hostname" "-p" "--project" "-m" "--milestone" "-r" "--reviewer" "-S"
    "--search" "-w" "--workflow" "--cache"})


(defn base
  [w]
  (let [w (str/replace w #"[\"'()]" "")]
    (if (str/blank? w)
      w
      (str (fs/file-name w)))))


(defn plain? [w] (and w (re-matches #"[a-z][a-z0-9-]*" w)))


(defn words [s] (remove str/blank? (str/split (str/trim (str s)) #"\s+")))


(defn command-words [seg] (drop-while #(or (lead-words %) (re-matches #"[A-Za-z_]\w*=.*" %)) (words seg)))


(defn split-top
  "Splits a shell command at && || ; | and newlines outside quotes."
  [^String s]
  (loop [i   0
         q   nil
         cur (StringBuilder.)
         out []]
    (if (>= i (count s))
      (conj out (str cur))
      (let [c  (.charAt s i)
            c2 (when (< (inc i) (count s)) (.charAt s (inc i)))
            op (cond (or (and (= c \&) (= c2 \&)) (and (= c \|) (= c2 \|))) 2
                     (#{\| \; \newline} c) 1)]
        (cond
          (and (= c \\) c2 (not= q \')) (recur (+ i 2) q (doto cur (.append c) (.append c2)) out)
          q (recur (inc i) (when (not= c q) q) (.append cur c) out)
          (#{\' \"} c) (recur (inc i) c (.append cur c) out)
          op (recur (+ i op) nil (StringBuilder.) (conj out (str cur)))
          :else (recur (inc i) q (.append cur c) out))))))


(defn segments
  "The simple commands of a shell command: heredoc bodies dropped, $(…) bodies added."
  [cmd]
  (let [s (-> (str cmd)
              (str/replace #"\\\n" " ")
              (str/replace #"(?s)<<-?\s*['\"]?(\w+)['\"]?([^\n]*)\n.*?\n[ \t]*\1[ \t]*(?=\n|$)" "$2"))]
    (concat (split-top s) (mapcat #(split-top (second %)) (re-seq #"\$\(([^()]*)\)" s)))))


(defn gh-args
  "gh's words without its flags and their values."
  [ws]
  (loop [[w & more] ws
         out        []]
    (cond (nil? w) out
          (gh-value-flags w) (recur (rest more) out)
          (str/starts-with? w "-") (recur more out)
          :else (recur more (conj out w)))))


(defn gh-api-write?
  [ws]
  (if-let [m (some (fn [[a b]]
                     (cond (#{"-X" "--method"} a)  b
                           (str/starts-with? a "--method=") (subs a 9)
                           (re-matches #"-X\w+" a) (subs a 2)))
                   (partition-all 2 1 ws))]
    (not= "GET" (str/upper-case (str m)))
    (boolean (some #{"-f" "-F" "--field" "--raw-field" "--input"} ws))))


(defn shape-of
  [[w & more]]
  (let [b (base w)]
    (case b
      "gh"  (let [[a c :as args] (gh-args more)]
              (cond (not= a "api")       (str/join " " (cons "gh" (filter plain? (take 2 args))))
                    (= c "graphql")      "gh api graphql"
                    (gh-api-write? more) "gh api (REST, write)"
                    :else                "gh api (REST)"))
      "git" (let [sub (first (remove #(str/starts-with? % "-")
                                     (loop [ws more]
                                       (if (#{"-C" "-c"} (first ws))
                                         (recur (drop 2 ws))
                                         ws))))]
              (if (plain? sub)
                (str "git " sub)
                "git"))
      ("bash" "sh" "zsh" "bb" "python" "python3" "node")
      (if (#{"-e" "-c"} (first more))
        (str b " " (first more))
        (let [[script sub] (remove #(or (str/starts-with? % "-") (re-find #"^\d*[<>&]" %)) more)
              file (some-> script base)]
          (str/join " "
                    (remove str/blank?
                            [b (when (and file (re-matches #"[\w.+-]+" file)) file)
                             (when (and (= b "bb") (plain? sub)) sub)]))))
      b)))


(defn shapes
  "The shapes of a command's parts, setting aside cd, echo and the like; a command made only of those is named
  by its first plain word."
  [tool input]
  (if (= tool "Bash")
    (let [segs  (segments (:command input))
          named (distinct (keep (fn [seg]
                                  (let [[w :as ws] (command-words seg)]
                                    (when (and w
                                               (not (skip-words w))
                                               (not (and (str/starts-with? w "$") (not (str/includes? w "/"))))
                                               (re-matches #"[A-Za-z][\w.+-]*" (base w)))
                                      (shape-of ws))))
                                segs))]
      (or (seq named) (some #(when (and (plain? %) (not= "cd" %)) [%]) (keep #(first (command-words %)) segs)) []))
    [(str tool)]))


(defn shape [tool input] (or (first (shapes tool input)) "shell"))


(defn shape-all
  [tool input]
  (let [s (shapes tool input)]
    (if (seq s)
      (str/join " + " (cond-> (vec (take 3 s)) (< 3 (count s)) (conj "…")))
      "shell")))


;; ------------------------------------------------------------------ ask rules


(defn glob-re
  "Bash(gh api *) or Read(/x/**) as a regex: * is anything; a trailing :* is a prefix too."
  [body]
  (re-pattern (str "^"
                   (str/join ".*" (map #(Pattern/quote %) (str/split (str/replace body #":\*$" "*") #"\*" -1)))
                   "$")))


(defn rule-matches?
  [tool input [_ t body]]
  (and (re-find (glob-re t) tool)
       (cond
         (nil? body)     true
         (= tool "Bash") (some #(re-find (glob-re body) (str/join " " (command-words %))) (segments (:command input)))
         (str/starts-with? body "domain:") (some-> (:url input) java.net.URI. .getHost (= (subs body 7)))
         :else           (some->> (some input [:file_path :notebook_path :path :url]) str (re-find (glob-re body))))))


(defn window-cause
  "The ask rule that raised a window, from the rules in force at that moment. Only a rule of plain words is
  printed whole; one naming a path or a URL prints as Tool(…)."
  [{:keys [tool input asks]}]
  (if-let [[r t body] (some #(let [p (re-matches #"([\w*-]+)(?:\((.*)\))?" %)]
                               (when (and p (rule-matches? tool input p)) p))
                            asks)]
    (str "ask rule: "
         (if (or (nil? body) (re-matches #"[\w .:*-]*" body))
           r
           (str t "(…)")))
    (str (shape-all tool input) " (no ask rule matches)")))


;; ------------------------------------------------------------------ the log


(defn log-dir
  []
  (str (fs/path (or (not-empty (System/getenv "XDG_STATE_HOME")) (str (System/getenv "HOME") "/.local/state"))
                "dev-kit"
                "friction")))


(defn read-log
  "Every event of the log, in order. A line that is not a whole event (a session still writing) is skipped."
  [dir]
  (vec (for [f     (sort (map str (fs/glob dir "*.jsonl")))
             line  (with-open [r (io/reader f)] (doall (line-seq r)))
             :let  [e (try (let [e (json/parse-string line true)]
                             ;; an event without a turn id belongs to no turn
                             (cond-> (assoc e :at (instant (:at e))) (str/blank? (str (:turn e))) (dissoc :turn)))
                           (catch Exception _ nil))]
             :when (and (:at e) (:session e))]
         e)))


(defn task-of
  [{:keys [branch origin]}]
  (when-let [[_ n] (some->> branch (re-matches #"(\d+)-.+"))] [(some-> origin str/lower-case) (parse-long n)]))


(defn runs
  "Commands sorted by time, split where neighbours are more than 10 minutes apart."
  [cmds]
  (reduce (fn [acc c]
            (let [prev (peek (peek acc))]
              (if (and prev (not (before? (.plus ^Instant (:at prev) (Duration/ofMinutes 10)) (:at c))))
                (conj (pop acc) (conj (peek acc) c))
                (conj acc [c]))))
          []
          cmds))


(defn pair
  "Calls in order, each with its window and outcome. A window goes to the first call of its turn with the same
  agent, tool and input that has neither yet."
  [events]
  (reduce (fn [calls e]
            (let [same (fn [ks] (fn [i c] (when (= (map c ks) (map e ks)) i)))]
              (case (:event e)
                "PreToolUse" (conj calls (assoc e :task (task-of e)))
                "PermissionRequest"
                (if-let [i (first (keep-indexed (fn [i c]
                                                  (when (and (nil? (:window c)) (nil? (:outcome c)))
                                                    ((same [:turn :agent :tool :input]) i c)))
                                                calls))]
                  (assoc-in calls [i :window] e)
                  calls)
                ("PostToolUse" "PostToolUseFailure" "PermissionDenied" "HookDenied")
                (if-let [i (first (keep-indexed (same [:id]) calls))]
                  (update calls i assoc :outcome (:event e) :reason (:reason e) :done (:at e))
                  calls)
                calls)))
          []
          events))


(defn session-friction
  "The friction in one session's events, {:items [{:kind :cause :at :task (:n)}] :messages [{:at :text :task}]}."
  [events]
  (let [calls    (pair events)
        turns    (distinct (keep :turn events))
        ended    (fn [ev] (into {} (for [e events :when (and (:turn e) (= ev (:event e)))] [(:turn e) e])))
        stop     (ended "Stop")
        failed   (ended "StopFailure")
        named    (memoize (fn [t]
                            (let [ts (set (keep :task (filter #(= t (:turn %)) calls)))]
                              (when (= 1 (count ts)) (first ts)))))
        ;; a message, an Esc, a failed turn or a question belongs to the task the session was last working on
        latest   (loop [[t & more] turns
                        prev       nil
                        out        {}]
                   (if t
                     (let [n (or (named t) prev)] (recur more n (assoc out t n)))
                     out))
        item     (fn [kind cause c] {:kind kind :cause cause :at (:at c) :task (or (:task c) (named (:turn c)))})
        first-at (fn [t] (:at (first (filter #(= t (:turn %)) events))))
        dialog   #{"AskUserQuestion" "ExitPlanMode"}
        call     (fn [{:keys [tool input window outcome reason turn] :as c}]
                   (let [ran? (#{"PostToolUse" "PostToolUseFailure"} outcome)]
                     (cond-> []
                       (= tool "AskUserQuestion") (conj (item :question "AskUserQuestion" c))
                       (= tool "ExitPlanMode") (conj (item :plan (if ran? "approved" "declined") c))
                       (and window (not (dialog tool)))
                       (conj (item (if ran? :confirm-yes :confirm-no) (window-cause window) c))
                       (= outcome "HookDenied") (conj (item :refusal-hook (shape-all tool input) c))
                       (= outcome "PermissionDenied")
                       (conj (item :refusal-classifier
                                   (str (shape-all tool input)
                                        " — "
                                        (or (second (re-find #"\[(\w+)\]" (str reason))) "classifier"))
                                   c))
                       (= outcome "PostToolUseFailure") (conj (item :tool-error (shape tool input) c))
                       (and (nil? outcome) (nil? window) (stop turn) (not (dialog tool)))
                       (conj (item :refusal-rule (shape-all tool input) c)))))
        bash     (filter #(and (= "Bash" (:tool %)) (get-in % [:input :command])) calls)]
    {:items    (concat
                (mapcat call calls)
                ;; neither Stop nor StopFailure while the session went on: the owner pressed Esc, unless on a
                ;; window, which is that window's no
                (for [t     (butlast turns)
                      :when (and (not (stop t))
                                 (not (failed t))
                                 (not (some #(and (= t (:turn %)) (:window %) (nil? (:outcome %))) calls)))]
                  {:kind :interrupt :cause "—" :at (first-at t) :task (latest t)})
                (for [t (keys failed)] {:kind :turn-failed :cause "—" :at (first-at t) :task (latest t)})
                (for [[t e] stop
                      :when (:needs_input e)]
                  {:kind :question :cause "needs input in chat" :at (:at e) :task (latest t)})
                ;; the same command, word for word, three times or more within minutes: polling or retries
                (for [[_ same] (group-by #(str/join " " (words (get-in % [:input :command]))) bash)
                      run      (runs same)
                      :when    (>= (count run) 3)]
                  (assoc (item :repeat (shape "Bash" (:input (first run))) (first run)) :n (count run))))
     :messages (for [e     events
                     :when (= "UserPromptSubmit" (:event e))]
                 {:at (:at e) :text (:prompt e) :task (latest (:turn e))})
     ;; where the time went (#65): spans {:what :task :from :to}
     :time     (let [end  (fn [t] (:at (or (stop t) (failed t) (last (filter #(= t (:turn %)) events)))))
                     asks (filter #(= "UserPromptSubmit" (:event %)) events)
                     task (fn [c] (or (:task c) (named (:turn c))))]
                 (concat
                  (for [t turns] {:what :turn :task (latest t) :from (first-at t) :to (end t)})
                  ;; a window the owner answered, from the window to the run
                  (for [{:keys [window done tool] :as c} calls
                        :when (and window done (not (dialog tool)))]
                    {:what :window :task (task c) :from (:at window) :to done})
                  ;; a question: AskUserQuestion until answered; "needs input" until the owner's next message
                  (for [c     calls
                        :when (and (= "AskUserQuestion" (:tool c)) (:done c))]
                    {:what :question :task (task c) :from (:at c) :to (:done c)})
                  (for [[t e] stop
                        :when (:needs_input e)
                        :let  [answer (:at (first (filter #(before? (:at e) (:at %)) asks)))]
                        :when answer]
                    {:what :question :task (latest t) :from (:at e) :to answer})
                  (for [{:keys [window done tool input] :as c} calls
                        :when (and done (nil? window) (not (dialog tool)))]
                    {:what :command :task (task c) :from (:at c) :to done :shape (shape tool input)})))}))


;; ------------------------------------------------------------------ GitHub


(def query
  (str
   "query($o:String!,$n:String!,$i:Int!){repository(owner:$o,name:$n){issue(number:$i){"
   "labels(first:50){nodes{name}}"
   " timelineItems(itemTypes:[LABELED_EVENT],last:50){nodes{... on LabeledEvent{actor{login} label{name} createdAt}}}"
   " comments(first:100){nodes{body createdAt}}"
   " closedByPullRequestsReferences(first:5,includeClosedPrs:true){nodes{number createdAt mergedAt additions deletions"
   " changedFiles commits(first:100){nodes{commit{statusCheckRollup{state}}}}"
   " reviews(first:100){nodes{author{login} state submittedAt}}"
   " timelineItems(itemTypes:[REVIEW_DISMISSED_EVENT,READY_FOR_REVIEW_EVENT],last:50){nodes{__typename"
   " ... on ReviewDismissedEvent{createdAt} ... on ReadyForReviewEvent{createdAt}}}"
   " comments(first:100){nodes{body}}}}}}}"))


(defn nodes [m & path] (get-in m (concat path ["nodes"])))


(defn github-lines
  [gh repo n agent]
  (let [[o r]     (str/split repo #"/")
        issue     (or (get-in (json/parse-string (gh "api" "graphql"
                                                     "-f"  (str "query=" query)
                                                     "-f"  (str "o=" o)
                                                     "-f"  (str "n=" r)
                                                     "-F"  (str "i=" n)))
                              ["data" "repository" "issue"])
                      (throw (ex-info (str repo "#" n " not found") {})))
        size      (some #(second (re-matches #"size:(XS|S|M|L|XL)" (get % "name"))) (nodes issue "labels"))
        design    (->> (nodes issue "comments")
                       (filter #(str/starts-with? (str (get % "body")) "## Design"))
                       (map #(instant (get % "createdAt")))
                       sort
                       first)
        approvals (->> (nodes issue "timelineItems")
                       (filter #(and (= "design-approved" (get-in % ["label" "name"]))
                                     (not= agent (get-in % ["actor" "login"]))))
                       (map #(instant (get % "createdAt")))
                       sort)
        after     (when design (first (remove #(before? % design) approvals)))
        all-prs   (nodes issue "closedByPullRequestsReferences")]
    (cons
     (str "- Design approval: "
          (cond after  (str (count approvals) ", " (span design after) " after the first `## Design` comment")
                (and design (seq approvals)) (str (count approvals) ", all before the first `## Design` comment")
                design "the `## Design` comment was never approved"
                :else  (str "none (no `## Design` comment" (when size (str "; Size " size)) ")")))
     (for [pr   (or (seq (filter #(get % "mergedAt") all-prs)) all-prs)
           :let [reviews  (remove #(= agent (get-in % ["author" "login"])) (nodes pr "reviews"))
                 approved (sort (keep #(when (= "APPROVED" (get % "state")) (instant (get % "submittedAt"))) reviews))
                 events   (nodes pr "timelineItems")
                 ready-ev (last (sort (keep #(when (= "ReadyForReviewEvent" (get % "__typename"))
                                               (instant (get % "createdAt")))
                                            events)))
                 ready    (or ready-ev (instant (get pr "createdAt")))
                 approve  (first (remove #(before? % ready) approved))
                 merged   (instant (get pr "mergedAt"))
                 rollups  (keep #(get-in % ["commit" "statusCheckRollup" "state"]) (nodes pr "commits"))
                 steps    (filter #(re-find #"(?m)^##\s*(Что сделать руками|Owner steps)" (str (get % "body")))
                                  (nodes pr "comments"))]]
       (str/join "\n"
                 [(str "- PR #" (get pr "number")
                       ": +" (get pr "additions")
                       " −" (get pr "deletions")
                       " in "
                       (get pr "changedFiles")
                       " files, " (count (nodes pr "commits"))
                       " commits; Size " (or size "not set"))
                  (str "- Review rounds with comments: "
                       (count (filter #(#{"COMMENTED" "CHANGES_REQUESTED"} (get % "state")) reviews))
                       "; approvals: " (count approved)
                       "; dismissed: " (count (filter #(= "ReviewDismissedEvent" (get % "__typename")) events)))
                  (str "- Waiting on the owner: PR "
                       (if ready-ev "ready" "opened")
                       " → Approve "
                       (if approve
                         (span ready approve)
                         "no approval")
                       (when (and approve merged) (str "; Approve → merged " (span approve merged))))
                  (str "- CI: " (count (filter #{"FAILURE" "ERROR"} rollups)) " of " (count rollups) " commits failed")
                  (str "- Owner steps: "
                       (if (seq steps)
                         (str (count steps)
                              " comment"
                              (when (< 1 (count steps)) "s")
                              ", "
                              (reduce + (map #(count (re-seq #"(?m)^\d+\.\s" (str (get % "body")))) steps))
                              " steps")
                         "none"))])))))


;; ------------------------------------------------------------------ the report


(def kinds
  [[:confirm-yes "Confirmation: yes"] [:confirm-no "Confirmation: no"] [:question "Question to the owner"]
   [:plan "Plan for approval"] [:interrupt "Owner interrupted (Esc)"] [:turn-failed "Turn failed (API error)"]
   [:refusal-hook "Refused by a hook"] [:refusal-classifier "Refused by the classifier"]
   [:refusal-rule "Refused by a rule"] [:tool-error "Tool error"] [:repeat "Same command 3+ times"]])


(def label (into {} kinds))


(def rank (into {} (map-indexed (fn [i [k]] [k i]) kinds)))


(defn tally [items] (reduce (fn [m i] (update m [(:kind i) (:cause i)] (fnil + 0) (:n i 1))) {} items))


(defn ordered [m] (sort-by (fn [[[k c]]] [(rank k) c]) m))


(defn one-line [s] (str/trim (str/replace (str s) #"\s+" " ")))


(defn seconds [spans] (reduce + (map #(.getSeconds (Duration/between (:from %) (:to %))) spans)))


(defn minutes
  "A duration as people read it: 45s, 12m, 1h 05m."
  [secs]
  (let [m (quot secs 60)]
    (cond (< secs 60) (str secs "s")
          (>= m 60)   (format "%dh %02dm" (quot m 60) (rem m 60))
          :else       (str m "m"))))


(defn time-lines
  "Where the task's time went: its turns, waiting on the owner, the commands."
  [spans]
  (let [of      (fn [what] (filter #(= what (:what %)) spans))
        longest (->> (of :command) (filter #(>= (seconds [%]) 60)) (sort-by #(- (seconds [%]))) (take 3))]
    (when (seq spans)
      [""
       (if (seq (of :turn))
         (str "Time of the task: " (count (of :turn)) " turns, " (minutes (seconds (of :turn))) " in all")
         ;; a turn that worked on several tasks belongs to none of them
         "Time of the task: its turns also served other tasks, so their time is not split")
       (str "- waiting on the owner: " (count (of :window))
            " confirmation windows, " (minutes (seconds (of :window)))
            "; " (count (of :question))
            " questions, " (minutes (seconds (of :question))))
       (str "- commands: "
            (minutes (seconds (of :command)))
            (when (seq longest)
              (str "; the longest: "
                   (str/join ", " (for [c longest] (str (:shape c) " " (minutes (seconds [c]))))))))])))


(defn mark? [text] (re-find #"(?iu)^\s*(трение|friction)\s*:" (str text)))


(defn log-lines
  [{:keys [repo issue now messages]}]
  (let [dir (log-dir)]
    (if-not (seq (fs/glob dir "*.jsonl"))
      ["Friction log: not available — the recorder (dev-kit #55) has written nothing on this machine yet."]
      (let [found     (map session-friction (vals (group-by :session (read-log dir))))
            mine?     #(= [(str/lower-case repo) issue] (:task %))
            items     (mapcat :items found)
            own       (filter mine? items)
            said      (filter mine? (mapcat :messages found))
            marks     (filter #(mark? (:text %)) said)
            others    (remove #(mark? (:text %)) said)
            spans     (filter mine? (mapcat :time found))
            times     (sort (concat (map :at (concat own said)) (map :from spans)))
            fortnight (tally (remove #(before? (:at %) (.minus ^Instant now (Duration/ofDays 14))) items))]
        (concat
         [(if (seq times)
            (str "Friction log on this machine: "
                 (reduce + (map #(:n % 1) own))
                 " events of the task, "
                 (stamp (first times))
                 " → "
                 (stamp (last times))
                 " UTC. The 14-day column counts every task and project on this machine.")
            "Friction log on this machine: no events of this task.")
          ""]
         (when (seq own)
           (concat ["| Kind | Cause | This task | 14 days |" "|---|---|---|---|"]
                   (for [[[k c] n] (ordered (tally own))]
                     (str "| " (label k) " | " c " | " n " | " (get fortnight [k c] 0) " |"))))
         (time-lines spans)
         (when-let [recurring (seq (ordered (filter #(>= (val %) 3) fortnight)))]
           (concat ["" "Recurring in the last 14 days (3 or more, whichever task):"]
                   (for [[[k c] n] recurring] (str "- " (label k) " · " c ": " n))))
         (when (seq marks)
           (concat ["" "The owner's marks:"] (for [m marks] (str "- " (stamp (:at m)) " " (one-line (:text m))))))
         [""
          (str "Owner messages: "
               (count others)
               " (classify them locally with `kit retro "
               issue
               " --messages`; publish only counts and paraphrases)")]
         (when messages
           (concat ["" "Owner messages (local only, never publish):"]
                   (for [m    others
                         :let [t (one-line (:text m))]]
                     (str "- " (stamp (:at m)) " " (subs t 0 (min 300 (count t))))))))))))


(defn run
  [{:keys [issue repo agent gh now] :as opts}]
  (let [now (if now
              (parse-time "--now" now)
              (Instant/now))]
    (println (str "## Friction data: " repo "#" issue))
    (println)
    (doseq [l (log-lines (assoc opts :now now))] (println l))
    (println)
    (println "### GitHub")
    (doseq [l (try (github-lines gh repo issue agent)
                   (catch Exception e [(str "GitHub: not available (" (ex-message e) ")")]))]
      (println l))))


;; ------------------------------------------------------------------ the gate (#56)
;; New work waits while a task merged in the last 14 days lacks its `## Retrospective` comment: the start script
;; and the session's start ask this, and only the owner can waive it.


(def missing-query
  (str
   "query($q:String!){search(query:$q,type:ISSUE,first:50){nodes{... on Issue{number title"
   " comments(last:100){nodes{body}} closedByPullRequestsReferences(first:5,includeClosedPrs:true){nodes{mergedAt}}}}}}"))


(defn missing
  "[number title] of the issues closed as completed by a merged PR since `since` that lack a retrospective."
  [gh repo ^Instant since]
  (let [q (str "repo:" repo " is:issue is:closed reason:completed closed:>=" (subs (str since) 0 10))]
    (for [i     (get-in (json/parse-string (gh "api" "graphql" "-f" (str "query=" missing-query) "-f" (str "q=" q)))
                        ["data" "search" "nodes"])
          :when (and (some #(get % "mergedAt") (nodes i "closedByPullRequestsReferences"))
                     (not-any? #(str/starts-with? (str/trim (str (get % "body"))) "## Retrospective")
                               (nodes i "comments")))]
      [(get i "number") (get i "title")])))


(defn run-missing
  "Exit 0 and silence when every merged issue has its retrospective; exit 1 with the list and the fix; exit 2
  when GitHub cannot be asked."
  [{:keys [repo gh now]}]
  (let [now   (if now
                (parse-time "--now" now)
                (Instant/now))
        found (try (doall (missing gh repo (.minus ^Instant now (Duration/ofDays 14))))
                   (catch Exception e
                     (binding [*out* *err*]
                       (println (str "kit: retro: GitHub not available: " (ex-message e)))
                       (flush))
                     (System/exit 2)))]
    (when (seq found)
      (println (str "Merged in the last 14 days without a `## Retrospective` comment: "
                    (str/join ", " (for [[n t] found] (str "#" n " " t)))
                    "."))
      (println (str "Post each one's retrospective before new work (repo-task-delivery, stage 11); its data comes from"
                    " kit retro <n>, e.g. kit retro "
                    (ffirst found)
                    "."))
      (println "Only the owner can waive this: the same start command with --skip-retro asks the owner first.")
      (flush)
      (System/exit 1))))
