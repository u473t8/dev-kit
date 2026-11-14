;; The GitHub steps of the delivery flow (#95, ADR-0005), loaded by bin/kit:
;;
;;   kit start    files the issue (or reuses one), puts it on the board with its fields, creates its branch
;;   kit finish   commits, pushes, opens the pull request, turns on auto-merge, sets the card In review
;;   kit merge    after the owner's Approve: waits for the merge, sets the card Done, removes the branch
;;   kit board set <project-number> <owner> <issue-url> <field> <option>   one field of one card (#41)
;;
;; They were start_issue_flow.sh, finish_issue_flow.sh, merge_issue_flow.sh and board.sh: the same options, the
;; same output lines and exit codes. gh's JSON is read as data, so the flow needs no jq.
(ns flow
  (:require
    [babashka.fs :as fs]
    [babashka.process :as p]
    [cheshire.core :as json]
    [clojure.string :as str]))


;; ------------------------------------------------------------------ plumbing

(defn die [& msg]
  (binding [*out* *err*] (println (str "Error: " (str/join " " msg))))
  (System/exit 1))


(defn warn [& msg]
  (binding [*out* *err*] (println (str/join " " msg))))


(defn run
  "A command's {:exit :out :err}, its output captured."
  [& args]
  (apply p/sh {:continue true} args))


(defn shell
  "A command whose output goes to ours, as in a terminal; its exit code."
  [& args]
  (:exit @(apply p/process {:inherit true} args)))


(defn gh-out
  "gh's trimmed stdout; nil when it fails."
  [& args]
  (let [{:keys [exit out]} (apply run "gh" args)]
    (when (zero? exit) (str/trim out))))


(defn ok!
  "Ends the run with a failed command's own exit code, as the scripts did under `set -e`."
  [exit]
  (when-not (zero? exit) (System/exit exit)))


(defn gh!
  "gh's trimmed stdout, as `$(gh …)` read it: its messages go to our stderr, and a failure ends the run with gh's exit
  code. A failure that says nothing is named here: the command and its exit code."
  [& args]
  (let [{:keys [exit out err]} @(apply p/process {:out :string :err :string} "gh" args)]
    (when-not (str/blank? err) (binding [*out* *err*] (print err) (flush)))
    (when (and (not (zero? exit)) (str/blank? err))
      (warn (str "Error: gh " (str/join " " (take 2 args)) " failed with exit code " exit " and printed no message. "
                 "Run the same call by hand to see why.")))
    (ok! exit)
    (str/trim out)))


(defn file-text
  "A file as `$(cat file)` reads it: without its trailing newlines."
  [path]
  (str/replace (slurp path) #"\n+$" ""))


(defn last-line [s] (some-> s str/split-lines last (str/replace "\r" "") str/trim))


(defn shell-quote
  "A word as bash's printf %q would write it."
  [s]
  (if (re-matches #"[A-Za-z0-9_@%+=:,./-]+" s) s (str "'" (str/replace s "'" "'\\''") "'")))


(defn parse-opts
  "Options against a spec: {\"--flag\" [:key :value|:flag|:many]}. Unknown ones end the run."
  [spec args]
  (loop [[a & more] args opts {}]
    (if (nil? a)
      opts
      (let [[k kind] (spec a)]
        (case kind
          :value (recur (rest more) (assoc opts k (first more)))
          :many (recur (rest more) (update opts k (fnil conj []) (first more)))
          ;; --help answers at once, as the scripts' `case` did, whatever follows it.
          :flag (if (= k :help) {:help true} (recur more (assoc opts k true)))
          (die "Unknown argument:" a))))))


(defn env [k default] (or (not-empty (System/getenv k)) default))


(defn resolve-repo
  "owner/name: --repo, then the folder's GitHub origin, then GHWF_REPO. The folder comes before the session (#81):
  a session opened in one project may work in another repository's worktree."
  [repo]
  (or (not-empty repo)
      (let [url (some-> (run "git" "remote" "get-url" "origin") :out str/trim (str/replace #"/$" "") (str/replace #"\.git$" ""))]
        (second (re-find #"github\.com[:/]([^/]+/[^/]+)$" (or url ""))))
      (not-empty (System/getenv "GHWF_REPO"))
      (do (binding [*out* *err*]
            (println "Error: no repository: this folder has no GitHub origin and GHWF_REPO is not set; run inside the clone, or pass --repo owner/name"))
          (System/exit 1))))


(defn issue-branch-number [branch] (second (re-matches #"(\d+)-.*" branch)))


;; ------------------------------------------------------------------ board (#22, #41)

(defn board-hint
  "The likely cause of a board error and its fix, or nil."
  [msg]
  (cond
    (re-find #"INSUFFICIENT_SCOPES|required scopes|missing required scope" msg)
    (str "the gh login in use lacks the project scope: in your own terminal, GH_CONFIG_DIR="
         (env "GH_CONFIG_DIR" "~/.config/gh") " gh auth refresh -h github.com -s project")

    (re-find #"Could not resolve to a ProjectV2|Could not resolve to a User|NOT_FOUND" msg)
    "no access to the board: check that it exists and that this gh account can write to it (the board's Settings > Manage access)"

    (re-find #"HTTP 5|Bad Gateway|Service Unavailable|timed out|timeout|connection reset|Something went wrong" msg)
    "GitHub had an error: run the command again"))


(defn board-reason [msg] (str msg (some->> (board-hint msg) (str "; "))))


(defn- board-gh!
  "gh, run once more after a passing GitHub error (#41). Its trimmed stdout, or an exception with its message."
  [& args]
  (let [once  #(apply run "gh" args)
        r     (once)
        r     (if (and (not (zero? (:exit r))) (some-> (board-hint (:err r)) (str/starts-with? "GitHub had an error")))
                (once)
                r)]
    (if (zero? (:exit r))
      (str/trim (:out r))
      (throw (ex-info (str/trim (:err r)) {:board true})))))


(def ^:private board-cache (atom {}))


(defn board-set-field
  "Sets a single-select field of an issue's card. The card is found through the project: `item-add` returns the card
  an issue already has and adds a missing one. gh's by-URL mode found it through the issue, and an organization's
  issue does not list a user's board (#22). nil, or why it failed."
  [number owner url field option]
  (try
    (let [number (str number)
          item   (board-gh! "project" "item-add" number "--owner" owner "--url" url "--format" "json" "--jq" ".id")
          pid    (or (:pid @board-cache)
                     (:pid (swap! board-cache assoc :pid
                                  (board-gh! "project" "view" number "--owner" owner "--format" "json" "--jq" ".id"))))
          fields (or (:fields @board-cache)
                     (:fields (swap! board-cache assoc :fields
                                     (json/parse-string (board-gh! "project" "field-list" number "--owner" owner
                                                                   "--format" "json" "--limit" "100")
                                                        true))))
          f      (some #(when (= field (:name %)) %) (:fields fields))
          o      (some #(when (= option (:name %)) %) (:options f))]
      (cond
        (nil? f) (str "board " number " has no field '" field "'; its fields: " (str/join ", " (map :name (:fields fields)))
                      ". Use one of them, or add the field on the board")
        (nil? o) (str "the field '" field "' of board " number " has no option '" option "'; its options: "
                      (str/join ", " (map :name (:options f))) ". Use one of them, or add the option on the board")
        :else (do (board-gh! "project" "item-edit" "--id" item "--project-id" pid "--field-id" (:id f)
                             "--single-select-option-id" (:id o))
                  nil)))
    (catch clojure.lang.ExceptionInfo e (ex-message e))))


(defn board-set-command
  "The command that sets one field alone, as an error prints it."
  [kit number owner url field option]
  (str/join " " (map shell-quote ["bb" kit "board" "set" (str number) owner url field option])))


(defn board!
  [_kit args]
  (when-not (and (= "set" (first args)) (= 6 (count args)))
    (binding [*out* *err*] (println "Usage: kit board set <project-number> <owner> <issue-url> <field> <option>"))
    (System/exit 2))
  (let [[_ number owner url field option] args]
    (when-let [e (board-set-field number owner url field option)]
      (binding [*out* *err*] (println e))
      (System/exit 1))
    (println (str field ": " option))))


;; ------------------------------------------------------------------ kit start

(def start-usage
  "Usage: kit start --title <title> [options]

Create work in GitHub Project, assign fields, ensure issue exists, and create/checkout dev branch.

Options:
  --title <text>                Required issue or draft title
  --body <text>                 Body text
  --body-file <path>            Body file path
  --labels <csv>                Comma-separated labels
  --assignees <csv>             Comma-separated assignees (supports @me)
  --issue <number>              Reuse existing issue number instead of creating one
  --showcase <option>           Showcase field option (default: GHWF_SHOWCASE)
  --priority <option>           Required. Priority field option: Urgent|High|Medium|Low
  --size <option>               Size field option to set
  --milestone <title>           Open milestone to put the issue in (must already exist)
  --status <option>             Status field option to set (default: In progress with --issue, else
                                GHWF_DEFAULT_STATUS or Backlog)
  --mode <issue|draft-convert>  Default: issue
  --owner <login>               Project owner (default: GHWF_OWNER)
  --repo <owner/repo>           Repo (default: the folder's origin on GitHub, then GHWF_REPO)
  --project-number <number>     Project number (default: GHWF_PROJECT_NUMBER)
  --showcase-field <name>       Field name (default: GHWF_SHOWCASE_FIELD or Showcase)
  --priority-field <name>       Field name (default: GHWF_PRIORITY_FIELD or Priority)
  --size-field <name>           Field name (default: GHWF_SIZE_FIELD or Size)
  --status-field <name>         Field name (default: GHWF_STATUS_FIELD or Status)
  --base <branch>               Base branch for dev branch (default: GHWF_DEFAULT_BASE or main)
  --branch-name <name>          Override branch name
  --no-reuse-existing           Do not reuse exact-title project item or issue
  --skip-branch                 Do not create the development branch at all
  --no-checkout                 Create and link the branch, leave the calling worktree alone
                                (mutually exclusive with --skip-branch)
  --skip-retro                  Start although a merged issue lacks its retrospective. Only the owner
                                waives this: a permission rule asks them first (#56)
  --help                        Show this help")


(def start-spec
  {"--title" [:title :value] "--body" [:body :value] "--body-file" [:body-file :value]
   "--labels" [:labels :value] "--assignees" [:assignees :value] "--issue" [:issue :value]
   "--showcase" [:showcase :value] "--priority" [:priority :value] "--size" [:size :value]
   "--milestone" [:milestone :value] "--status" [:status :value] "--mode" [:mode :value]
   "--owner" [:owner :value] "--repo" [:repo :value] "--project-number" [:project-number :value]
   "--showcase-field" [:showcase-field :value] "--priority-field" [:priority-field :value]
   "--size-field" [:size-field :value] "--status-field" [:status-field :value] "--base" [:base :value]
   "--branch-name" [:branch-name :value] "--no-reuse-existing" [:no-reuse :flag] "--skip-branch" [:skip-branch :flag]
   "--no-checkout" [:no-checkout :flag] "--skip-retro" [:skip-retro :flag] "--help" [:help :flag] "-h" [:help :flag]})


(def items-query
  "query($owner: String!, $number: Int!, $status: String!, $after: String) {
      owner: repositoryOwner(login: $owner) {
        ... on ProjectV2Owner {
          projectV2(number: $number) {
            items(first: 100, after: $after) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                isArchived
                status: fieldValueByName(name: $status) { ... on ProjectV2ItemFieldSingleSelectValue { name } }
                content {
                  __typename
                  ... on Issue { number url title state }
                  ... on PullRequest { number url title }
                  ... on DraftIssue { title }
                }
              }
            }
          }
        }
      }
    }")


(defn project-items
  "The board's cards, not archived ones: they are out of the CLI's listing too, and reusing one would resurrect work
  the owner had put away. Only the four fields a match needs are asked for: `gh project item-list` asks for every
  field of every card, 203 points of the 5000 hourly GraphQL budget on a board this size."
  [owner number status-field]
  (loop [after nil items []]
    (let [page  (json/parse-string
                  (apply gh! "api" "graphql" "-f" (str "query=" items-query) "-F" (str "owner=" owner)
                         "-F" (str "number=" number) "-f" (str "status=" status-field)
                         (when after ["-F" (str "after=" after)]))
                  true)
          conn  (get-in page [:data :owner :projectV2 :items])
          items (into items
                      (for [n (:nodes conn) :when (not (:isArchived n))]
                        {:id      (:id n)
                         :title   (get-in n [:content :title] "")
                         :status  (get-in n [:status :name] "")
                         :content {:type   (get-in n [:content :__typename])
                                   :number (get-in n [:content :number])
                                   :url    (get-in n [:content :url])
                                   :state  (get-in n [:content :state])}}))]
      (if (get-in conn [:pageInfo :hasNextPage])
        (recur (get-in conn [:pageInfo :endCursor]) items)
        items))))


(defn find-item-by-title
  "One board serves several repositories, so a title only matches an issue of this repo, or a draft, which belongs to
  no repo yet. Only open work counts (#12): a closed issue or a Done card with a recurring title is history."
  [items title repo]
  (let [done (env "GHWF_DONE_STATUS" "Done")]
    (some #(when (and (= title (:title %))
                      (or (= "DraftIssue" (get-in % [:content :type]))
                          (and (= "Issue" (get-in % [:content :type]))
                               (str/starts-with? (or (get-in % [:content :url]) "") (str "https://github.com/" repo "/"))))
                      (not= "CLOSED" (get-in % [:content :state]))
                      (not= done (:status %)))
             %)
          items)))


(defn start!
  [kit args]
  (let [o (parse-opts start-spec args)
        _ (when (:help o) (println start-usage) (System/exit 0))
        title           (:title o)
        owner           (or (:owner o) (env "GHWF_OWNER" nil))
        project-number  (or (:project-number o) (env "GHWF_PROJECT_NUMBER" nil))
        showcase-field  (or (:showcase-field o) (env "GHWF_SHOWCASE_FIELD" "Showcase"))
        priority-field  (or (:priority-field o) (env "GHWF_PRIORITY_FIELD" "Priority"))
        size-field      (or (:size-field o) (env "GHWF_SIZE_FIELD" "Size"))
        status-field    (or (:status-field o) (env "GHWF_STATUS_FIELD" "Status"))
        base            (or (:base o) (env "GHWF_DEFAULT_BASE" "main"))
        assignees       (or (:assignees o) (env "GHWF_DEFAULT_ASSIGNEES" "@me"))
        showcase        (or (:showcase o) (env "GHWF_SHOWCASE" nil))
        priority        (or (:priority o) (env "GHWF_DEFAULT_PRIORITY" nil))
        size            (or (:size o) (env "GHWF_DEFAULT_SIZE" nil))
        status          (or (:status o) (when (:issue o) "In progress") (env "GHWF_DEFAULT_STATUS" "Backlog"))
        mode            (or (:mode o) "issue")
        _ (when (str/blank? title) (die "--title is required"))
        _ (when (str/blank? owner) (die "--owner or GHWF_OWNER is required"))
        repo            (resolve-repo (:repo o))
        _ (when (str/blank? project-number) (die "--project-number or GHWF_PROJECT_NUMBER is required"))
        _ (when-not (#{"issue" "draft-convert"} mode) (die "--mode must be 'issue' or 'draft-convert'"))
        _ (when (and (:skip-branch o) (:no-checkout o))
            (die "--skip-branch and --no-checkout are mutually exclusive: one creates no branch, the other creates one without touching the working tree"))]
    ;; Checked before anything is created: a run that files the issue and then dies on the priority leaves
    ;; half-tracked work behind.
    (cond (str/blank? priority) (die "--priority is required: Urgent|High|Medium|Low")
          (not (#{"Urgent" "High" "Medium" "Low"} priority))
          (die (str "Priority '" priority "' is not on the scale Urgent|High|Medium|Low")))
    ;; An unknown milestone stops the run before an issue exists. Milestones are never created here.
    (when-let [m (:milestone o)]
      (let [open (str/split-lines (gh! "api" (str "repos/" repo "/milestones?state=open") "--paginate" "--jq" ".[].title"))]
        (when-not (some #{m} open)
          (die (str "Milestone '" m "' is not an open milestone of '" repo "'. Open: " (str/join "/" open))))))
    ;; A merged task's retrospective comes before new work (#28, #56). When GitHub cannot be asked, say so and go
    ;; on: the check guards the process, not data.
    (when-not (:skip-retro o)
      (let [{:keys [exit out err]} (run "bb" kit "retro" "--missing" "--repo" repo)
            said (str/trim (str out err))]
        (case (int exit)
          0 nil
          1 (die said)
          (warn "Warning: could not check for merged issues without a retrospective:" said))))
    (let [budget   #(some-> (gh-out "api" "rate_limit" "--jq" ".resources.graphql.remaining") not-empty parse-long)
          before   (budget)
          labels   (atom nil)
          known?   (fn [l]
                     (when-not @labels
                       (reset! labels (try (set (map :name (json/parse-string (gh-out "label" "list" "-R" repo "--limit" "200" "--json" "name") true)))
                                           (catch Exception _ #{}))))
                     (@labels l))
          csv      #(remove str/blank? (map str/trim (str/split (or % "") #",")))
          label-args (fn [flag]
                       (mapcat (fn [l]
                                 (when-not (known? l)
                                   (when-not (zero? (:exit (run "gh" "label" "create" l "-R" repo)))
                                     (die (str "Label '" l "' does not exist in " repo " and could not be created: create it on GitHub (Issues > Labels), or drop it from --labels")))
                                   (swap! labels conj l))
                                 [flag l])
                               (csv (:labels o))))
          assignee-args (fn [flag] (mapcat (fn [a] [flag a]) (csv assignees)))
          item-add (fn [url what & [then]]
                     (try (board-gh! "project" "item-add" project-number "--owner" owner "--url" url "--format" "json" "--jq" ".id")
                          (catch clojure.lang.ExceptionInfo e (die (str what (board-reason (ex-message e)) then)))))
          convert  (fn [item-id]
                     (let [rid (gh! "repo" "view" repo "--json" "id" "--jq" ".id")
                           _   (when (str/blank? rid) (die "Failed to resolve repository id"))
                           ;; The schema (introspected, #12): input {itemId, repositoryId}, payload {item: ProjectV2Item}.
                           q   "mutation($itemId:ID!,$repositoryId:ID!){ convertProjectV2DraftIssueItemToIssue(input:{itemId:$itemId,repositoryId:$repositoryId}) { item { content { ... on Issue { number url } } } } }"
                           c   (get-in (json/parse-string (gh! "api" "graphql" "-f" (str "query=" q) "-F" (str "itemId=" item-id)
                                                               "-F" (str "repositoryId=" rid))
                                                          true)
                                       [:data :convertProjectV2DraftIssueItemToIssue :item :content])]
                       (when-not (and (:number c) (:url c)) (die "Draft item conversion to issue failed"))
                       [(str (:number c)) (:url c)]))
          use-item (fn [item]
                     (let [id (or (:id item) (die "Existing project item has no id"))]
                       (case (get-in item [:content :type])
                         "Issue" (let [n (get-in item [:content :number]) u (get-in item [:content :url])]
                                   (when-not (and n u) (die "Existing issue item is missing issue data"))
                                   [(str n) u id])
                         "DraftIssue" (conj (convert id) id)
                         (die (str "Existing project item '" title "' is not an issue or draft issue")))))
          ;; --issue N names the work: no title is matched, with reuse on or off (#12).
          [number url item-id]
          (cond
            (:issue o)
            (let [n (:issue o)
                  {:keys [exit out err]} (run "gh" "issue" "view" n "-R" repo "--json" "url" "--jq" ".url")
                  u (str/trim out)]
              (when-not (zero? exit)
                (die (str "Issue #" n " not found in " repo " (" (str/trim (str out err)) "): check the number, start without --issue, or pass --repo owner/name if that is the wrong repository")))
              [n u (item-add u (str "#" n " could not be put on the board: "))])

            (not (:no-reuse o))
            (if-let [item (find-item-by-title (project-items owner project-number status-field) title repo)]
              (use-item item)
              (when-let [issue (some #(when (= title (:title %)) %)
                                     (json/parse-string (or (gh-out "issue" "list" "-R" repo "--state" "open" "--search"
                                                                    (str title " in:title") "--limit" "20" "--json" "number,title,url")
                                                            "[]")
                                                        true))]
                (let [n (str (:number issue)) u (:url issue)]
                  (when (str/blank? u) (die "Existing issue is missing issue data"))
                  [n u (item-add u (str "#" n " could not be put on the board: "))]))))
          [number url item-id]
          (cond
            number [number url item-id]

            (= mode "issue")
            (let [u (last-line (apply gh! (concat ["issue" "create" "-R" repo "--title" title]
                                                  ;; gh issue create without a body asks for one, and without a terminal fails (#12)
                                                  (if (:body-file o) ["--body-file" (:body-file o)] ["--body" (or (:body o) "")])
                                                  (label-args "--label") (assignee-args "--assignee"))))
                  _ (when (str/blank? u) (die "Issue creation failed"))
                  n (last (str/split u #"/"))]
              [n u (item-add u (str "#" n " is filed but could not be put on the board: ")
                             (str ". Then run kit start again with --issue " n))])

            :else
            (let [body (if (:body-file o) (file-text (:body-file o)) (not-empty (:body o)))
                  item (json/parse-string (apply gh! (concat ["project" "item-create" project-number "--owner" owner "--title" title "--format" "json"]
                                                             (when body ["--body" body])))
                                          true)
                  id   (or (not-empty (:id item)) (die "Draft item creation failed"))]
              (conj (convert id) id)))]
      (let [edit (concat (label-args "--add-label") (assignee-args "--add-assignee")
                         (when (:milestone o) ["--milestone" (:milestone o)]))]
        (when (seq edit)
          (apply gh! "issue" "edit" number "-R" repo edit)))
      ;; A failed board update ends the run (#41): the issue exists, the board does not show it as asked.
      (let [field! (fn [field option]
                     (when-not (str/blank? option)
                       (when-let [e (board-set-field project-number owner url field option)]
                         (die (str "#" number " is filed, but its " field " on the board is not '" option "': "
                                   (board-reason e) ". Then run kit start again with --issue " number)))))]
        (field! showcase-field showcase)
        (field! priority-field priority)
        (field! size-field size)
        ;; The board's Size, mirrored as a size:* label: CI's design approval gate reads labels, it cannot read a
        ;; user's board (#26). Other size labels are removed.
        (when-not (str/blank? size)
          (run "gh" "label" "create" (str "size:" size) "-R" repo "--color" "BFD4F2"
               "--description" "Task size (ADR-0002), mirrors the board field" "--force")
          (let [old  (some-> (gh-out "issue" "view" number "-R" repo "--json" "labels" "--jq"
                                     ".labels[].name | select(startswith(\"size:\"))")
                             str/split-lines)
                gone (mapcat (fn [l] ["--remove-label" l]) (remove #(or (str/blank? %) (= % (str "size:" size))) old))]
            (when-not (zero? (:exit (apply run "gh" "issue" "edit" number "-R" repo "--add-label" (str "size:" size) gone)))
              (warn (str "Warning: could not set the label size:" size " on #" number)))))
        (field! status-field status))
      (let [branch
            (when-not (:skip-branch o)
              ;; `gh issue develop` with no --name appends -1 to a name already taken, so a rerun would fork a
              ;; duplicate branch. Handing it the branch already linked to the issue makes the run idempotent.
              (let [named (or (:branch-name o)
                              (some-> (gh-out "issue" "develop" "--list" number "-R" repo) str/split-lines first
                                      (str/split #"\t") first not-empty))
                    out   (last-line (apply gh! (concat ["issue" "develop" number "-R" repo]
                                                        (when-not (:no-checkout o) ["--checkout"])
                                                        (when-not (str/blank? base) ["--base" base])
                                                        (when named ["--name" named]))))]
                ;; --no-checkout leaves the working tree alone, so the name comes from the URL gh prints.
                (if (:no-checkout o)
                  (second (re-find #"/tree/(.*)$" (or out "")))
                  (some-> (run "git" "branch" "--show-current") :out str/trim))))]
        (println (str "Issue URL: " url))
        (println (str "Issue Number: " number))
        (println (str "Project Item ID: " item-id))
        (when-not (str/blank? branch)
          (println (str (if (:no-checkout o) "Branch: " "Checked Out Branch: ") branch)))
        ;; A run that quietly eats a tenth of the hourly budget is only noticed an hour later. Print the price.
        (when before
          (when-let [after (budget)]
            (println (str "GraphQL Cost: " (- before after) " points (" after " left this hour)"))))))))


;; ------------------------------------------------------------------ kit finish

(def finish-usage
  "Usage: kit finish [options]

Run from the issue branch (<number>-<slug>, made by kit start).

Commits what is staged (or the --add paths), pushes, opens the pull request and sets the
board Status to \"In review\". Never merges: merging is kit merge.

Subjects follow Conventional Commits with the issue in the scope:
  feat(GH-12): add landing page
GitHub appends the PR number on squash: \"feat(GH-12): add landing page (#13)\".

Options:
  --type <type>                 feat|fix|docs|refactor|test|perf|build|ci|chore (default: the type of
                                the branch's first commit, else feat)
  --summary <text>              Subject text after \"type(GH-n): \" (default: the issue title)
  --commit-message-file <path>  Full commit message (subject, body, trailers); overrides --summary for the commit
  --pr-body-file <path>         PR description. Required when the PR is opened. Must contain a line
                                \"ADR: none\" or \"ADR: adr/NNNN-....md\". \"Closes #<issue>\" is added if missing.
  --add <path>                  Stage this path before committing (repeatable)
  --no-commit                   Commit nothing; push and open the PR for commits already on the branch
  --repo <owner/repo>           Default: the folder's origin on GitHub, then GHWF_REPO
  --owner <login>               Board owner (default: GHWF_OWNER)
  --project-number <number>     Board number (default: GHWF_PROJECT_NUMBER)
  --base <branch>               Default: GHWF_DEFAULT_BASE or main
  --status-field <name>         Default: GHWF_STATUS_FIELD or Status
  --review-status <option>      Default: In review
  --help                        Show this help")


(def finish-spec
  {"--type" [:type :value] "--summary" [:summary :value] "--commit-message-file" [:message-file :value]
   "--pr-body-file" [:body-file :value] "--add" [:add :many] "--no-commit" [:no-commit :flag]
   "--repo" [:repo :value] "--owner" [:owner :value] "--project-number" [:project-number :value]
   "--base" [:base :value] "--status-field" [:status-field :value] "--review-status" [:review-status :value]
   "--help" [:help :flag] "-h" [:help :flag]})


(defn- git-out [& args] (some-> (apply run "git" args) :out str/trim))


(defn finish!
  [kit args]
  (let [o (parse-opts finish-spec args)
        _ (when (:help o) (println finish-usage) (System/exit 0))
        owner          (or (:owner o) (env "GHWF_OWNER" nil))
        project-number (or (:project-number o) (env "GHWF_PROJECT_NUMBER" nil))
        base           (or (:base o) (env "GHWF_DEFAULT_BASE" "main"))
        status-field   (or (:status-field o) (env "GHWF_STATUS_FIELD" "Status"))
        review-status  (or (:review-status o) (env "GHWF_REVIEW_STATUS" "In review"))
        ;; Without --type the PR follows the branch: the type of its first `type(GH-n): …` commit, else feat.
        ctype          (or (:type o)
                           (some->> (git-out "log" "--reverse" "--format=%s" (str "origin/" base "..HEAD"))
                                    str/split-lines first (re-find #"^([a-z]+)\(GH-[0-9]+\): ") second)
                           "feat")
        repo           (resolve-repo (:repo o))
        branch         (git-out "rev-parse" "--abbrev-ref" "HEAD")
        _ (when (= branch "HEAD") (die "Detached HEAD is not supported"))
        _ (when (= branch base) (die (str "On the base branch '" base "': run from the issue branch")))
        ;; The issue is the branch's number: CI's pull request gate accepts no other (#21).
        number         (or (issue-branch-number branch)
                           (die (str "The branch '" branch "' is not <number>-<slug>: open the issue with kit start and move the work to its branch")))
        ;; Everything that can be wrong with the inputs is checked before the commit and the push: a run that dies
        ;; after the push leaves a branch with no pull request and a confusing rerun.
        _ (when (and (:body-file o) (not (fs/readable? (:body-file o)))) (die (str "PR body file '" (:body-file o) "' not found")))
        _ (when (and (:message-file o) (not (fs/readable? (:message-file o))))
            (die (str "Commit message file '" (:message-file o) "' not found")))
        ;; Only an open pull request counts: `gh pr view <branch>` also returns closed and merged ones.
        pr-url         (not-empty (gh! "pr" "list" "-R" repo "--head" branch "--state" "open" "--json" "url" "--jq" ".[0].url // empty"))
        _ (when-not (or pr-url (:body-file o)) (die "--pr-body-file is required to open the pull request"))
        subject        (cond (:summary o) (str ctype "(GH-" number "): " (:summary o))
                             (:message-file o) (first (str/split-lines (slurp (:message-file o))))
                             :else (let [t (gh! "issue" "view" number "-R" repo "--json" "title" "--jq" ".title")]
                                     (str ctype "(GH-" number "): " (str/lower-case (subs t 0 (min 1 (count t)))) (subs t (min 1 (count t))))))
        ;; The title and the body pass the rules CI checks on the pull request (#21): one implementation, in kit.
        ;; The body is checked only when it becomes a new PR's body; an open PR keeps its own.
        shape          (apply run "bb" kit "gate" "--shape" "--branch" branch "--title" subject
                              (when (and (not pr-url) (:body-file o)) ["--body-file" (:body-file o)]))]
    (when-not (zero? (:exit shape))
      (die (str "The pull request would fail CI's shape check; nothing was committed or pushed:\n" (str/trimr (str (:out shape) (:err shape))))))
    (when-not (:no-commit o)
      (when (seq (:add o)) (ok! (apply shell "git" "add" "--" (:add o))))
      (when (zero? (:exit (run "git" "diff" "--cached" "--quiet")))
        (die "Nothing staged to commit (use --add <path>, or --no-commit)"))
      (ok! (if (:message-file o) (shell "git" "commit" "-F" (:message-file o)) (shell "git" "commit" "-m" subject))))
    (ok! (shell "git" "push" "-u" "origin" branch))
    (let [pr-url (or pr-url
                     (let [body (file-text (:body-file o))
                           body (if (re-find (re-pattern (str "(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?) #" number "\\b")) body)
                                  body
                                  (str "Closes #" number "\n\n" body))]
                       (last-line (gh! "pr" "create" "-R" repo "--base" base "--head" branch "--title" subject "--body" body))))
          reviewers (not-empty (System/getenv "GHWF_REVIEWERS"))
          human     (not-empty (System/getenv "GHWF_HUMAN"))
          edit      (concat (when reviewers ["--add-reviewer" reviewers]) (when human ["--add-assignee" human]))]
      ;; On the reviewers' desk, assigned to the person behind the agent (#52). Repeating it is harmless.
      (when-not human
        (warn "Warning: no GHWF_HUMAN, so the PR has no assignee. Fix: run 'kit init' (or 'kit identity') on this machine; it reads your own gh login."))
      (when (seq edit)
        (let [r (apply run "gh" "pr" "edit" pr-url edit)]
          (when-not (zero? (:exit r))
            (warn "Warning: could not request the review or set the assignee:" (str/trim (str (:out r) (:err r)))))))
      ;; The owner's Approve is the word to merge: with auto-merge on, GitHub merges once the owner approved the
      ;; latest commit, the checks passed and the branch contains the latest base.
      (let [r (run "gh" "pr" "merge" pr-url "--auto" "--squash")]
        (when-not (zero? (:exit r))
          (warn "Warning: auto-merge could not be turned on:" (str/trim (str (:out r) (:err r))))
          (warn "  Fix: the owner turns on Settings > General > 'Allow auto-merge' (dev-kit#37); until then kit merge merges after the Approve.")))
      ;; A failed board update ends the run (#41). The PR is open by now, so only the status is left to set.
      (when (not-any? str/blank? [owner project-number review-status])
        (let [url (gh-out "issue" "view" number "-R" repo "--json" "url" "--jq" ".url")]
          (if (str/blank? url)
            (warn (str "Warning: issue #" number " not found, Status not set"))
            (when-let [e (board-set-field project-number owner url status-field review-status)]
              (die (str "The pull request is open: " pr-url ". But the board " status-field " of #" number " is not '"
                        review-status "': " (board-reason e) ". Set it alone: "
                        (board-set-command kit project-number owner url status-field review-status)))))))
      (println (str "Subject: " subject))
      (println (str "PR URL: " pr-url))
      (println (str "Status: " review-status)))))


;; ------------------------------------------------------------------ kit merge

(def merge-usage
  "Usage: kit merge [options]

Run from the issue branch. When the pull request is open, it needs the owner's Approve of the
latest commit. A branch behind the base is first updated by merging the base into it, which
keeps the approval. It then turns on auto-merge (squash) and waits until GitHub reports the
pull request MERGED. When GitHub already merged it, only the closeout runs: board Status
\"Done\", the branch deleted locally and on GitHub, back to the base branch. A pull request that
did not merge keeps its branch.

Options:
  --repo <owner/repo>           Default: the folder's origin on GitHub, then GHWF_REPO
  --owner <login>               Board owner (default: GHWF_OWNER)
  --project-number <number>     Board number (default: GHWF_PROJECT_NUMBER)
  --base <branch>               Default: GHWF_DEFAULT_BASE or main
  --status-field <name>         Default: GHWF_STATUS_FIELD or Status
  --done-status <option>        Default: Done
  --help                        Show this help

Environment: GHWF_MERGE_WAIT, seconds to wait for GitHub to merge (default 900);
GHWF_MERGE_POLL, seconds between looks (default 10).")


(def merge-spec
  {"--repo" [:repo :value] "--owner" [:owner :value] "--project-number" [:project-number :value]
   "--base" [:base :value] "--status-field" [:status-field :value] "--done-status" [:done-status :value]
   "--help" [:help :flag] "-h" [:help :flag]})


(defn- dirty-die [url base]
  (die (str "The branch conflicts with " base ": " url ". Fix: merge " base " into the branch (git fetch origin && "
            "git merge origin/" base ") and resolve the conflicts, then push; the push dismisses the owner's Approve, "
            "so ask for it again.")))


(defn merge!
  [kit args]
  (let [o (parse-opts merge-spec args)
        _ (when (:help o) (println merge-usage) (System/exit 0))
        owner          (or (:owner o) (env "GHWF_OWNER" nil))
        project-number (or (:project-number o) (env "GHWF_PROJECT_NUMBER" nil))
        base           (or (:base o) (env "GHWF_DEFAULT_BASE" "main"))
        status-field   (or (:status-field o) (env "GHWF_STATUS_FIELD" "Status"))
        done-status    (or (:done-status o) (env "GHWF_DONE_STATUS" "Done"))
        repo           (resolve-repo (:repo o))
        branch         (git-out "rev-parse" "--abbrev-ref" "HEAD")
        _ (when (#{base "HEAD"} branch) (die (str "Run from the issue branch, not '" branch "'")))
        number         (or (issue-branch-number branch) (die (str "Branch '" branch "' is not <number>-<slug>")))
        seconds        (fn [k default]
                         (let [v (env k default)]
                           (or (parse-long v) (die (str k " is '" v "': give it a whole number of seconds, or unset it for " default)))))
        wait           (seconds "GHWF_MERGE_WAIT" "900")
        poll           (seconds "GHWF_MERGE_POLL" "10")
        pr-list        #(not-empty (gh! "pr" "list" "-R" repo "--head" branch "--state" % "--json" "url" "--jq" ".[0].url // empty"))
        open-url       (pr-list "open")
        pr-url
        (if-not open-url
          ;; Merged by GitHub's auto-merge after the owner's Approve: only the closeout is left.
          (let [u (or (pr-list "merged")
                      (die (str "No open or merged pull request for branch '" branch "' in " repo "; if that is the wrong repository, pass --repo owner/name")))]
            (println (str "Already merged by GitHub: " u))
            u)
          (let [[decision state] (str/split (gh! "pr" "view" open-url "--json" "reviewDecision,mergeStateStatus"
                                                 "--jq" "\"\\(.reviewDecision // \"NONE\") \\(.mergeStateStatus)\"")
                                            #"\s+")]
            (when-not (= decision "APPROVED")
              (die (str "Waiting for the owner's Approve of the latest commit (review: " decision "): " open-url)))
            (when (= state "DIRTY") (dirty-die open-url base))
            (when (= state "BEHIND")
              (println (str "The branch is behind " base ": merging " base " into it; the approval stays."))
              (ok! (shell "gh" "pr" "update-branch" open-url)))
            ;; Auto-merge merges at once when everything is in place, or as soon as the checks pass. Without
            ;; auto-merge in the repository, a plain squash merge works when nothing is pending.
            (let [r (run "gh" "pr" "merge" open-url "--auto" "--squash")]
              ;; A refusal is read against the PR's state first: one GitHub already merged needs no second try (#97).
              (when (and (not (zero? (:exit r)))
                         (not= "MERGED" (first (str/split (gh! "pr" "view" open-url "--json" "state,mergeStateStatus" "--jq" "\"\\(.state) \\(.mergeStateStatus)\"") #"\s+"))))
                (warn (str "Auto-merge not available (" (str/trim (str (:out r) (:err r))) "); trying a plain squash merge."))
                (when-not (zero? (shell "gh" "pr" "merge" open-url "--squash"))
                  (die (str "Could not merge " open-url ". If checks are still running, run this again when they pass; for a merge that waits by itself, the owner turns on Settings > General > 'Allow auto-merge' (dev-kit#37).")))))
            open-url))
        ;; Only a confirmed merge may delete the branch: cleaning up after a failed merge closes the pull request with
        ;; the work still in it. A branch can fall behind while it waits, when another pull request merges first;
        ;; auto-merge then waits for ever, since the base requires up-to-date branches, so the loop updates it (#72).
        read-state #(str/split (gh! "pr" "view" pr-url "--json" "state,mergeStateStatus" "--jq" "\"\\(.state) \\(.mergeStateStatus)\"") #"\s+")
        pr-state
        (loop [[pr-state merge-state] (read-state) waited 0]
          (if (or (= pr-state "MERGED") (>= waited wait))
            pr-state
            (do (when (= merge-state "DIRTY") (dirty-die pr-url base))
                (when (= merge-state "BEHIND")
                  (println (str "The branch fell behind " base " while waiting: merging " base " into it; the approval stays."))
                  (shell "gh" "pr" "update-branch" pr-url))
                (Thread/sleep (* 1000 poll))
                (recur (read-state) (+ waited (if (pos? poll) poll 1))))))]
    (when-not (= pr-state "MERGED")
      (die (str "Pull request is " pr-state ", not merged yet; auto-merge stays on and branch '" branch "' is kept. Run this again later: " pr-url)))
    ;; A failed board update ends the run with an error (#41), after the closeout below: the merge is done.
    (let [board-error
          (when (not-any? str/blank? [owner project-number])
            (let [url (gh! "issue" "view" number "-R" repo "--json" "url" "--jq" ".url")]
              (when-let [e (board-set-field project-number owner url status-field done-status)]
                (str "The board " status-field " of #" number " is not '" done-status "': " (board-reason e) ". Set it alone: "
                     (board-set-command kit project-number owner url status-field done-status)))))]
      ;; Leave the issue branch. When the base branch is checked out in another worktree, this one cannot switch to
      ;; it; it stays detached on the merged base instead.
      (ok! (shell "git" "fetch" "-q" "origin" base))
      (if (some #{(str "branch refs/heads/" base)} (str/split-lines (git-out "worktree" "list" "--porcelain")))
        (ok! (shell "git" "switch" "-q" "--detach" (str "origin/" base)))
        (do (ok! (shell "git" "switch" "-q" base))
            (ok! (shell "git" "pull" "-q" "--ff-only"))))
      (ok! (shell "git" "branch" "-D" branch))
      (when (zero? (:exit (run "git" "ls-remote" "--exit-code" "--heads" "origin" branch)))
        (ok! (shell "git" "push" "origin" "--delete" branch)))
      (println (str "Merged: " pr-url))
      (when board-error (die board-error))
      (println (str "Status: " done-status)))))


;; ------------------------------------------------------------------ entry

(defn main
  "kit start | finish | merge | board, with the path of bin/kit for the commands that call it back."
  [cmd args kit]
  (case cmd
    "start" (start! kit args)
    "finish" (finish! kit args)
    "merge" (merge! kit args)
    "board" (board! kit args)))
