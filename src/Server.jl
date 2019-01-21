module RegServer

using GitHub
using DataStructures
using HTTP

function get_backtrace(ex)
    v = IOBuffer()
    Base.showerror(v, ex, catch_backtrace())
    return v.data |> copy |> String
end

"""Start a github webhook listener to process events"""
function start_github_webhook(http_ip=DEFAULT_HTTP_IP, http_port=DEFAULT_HTTP_PORT)
    listener = GitHub.EventListener(event_handler; auth=GitHub.authenticate(GITHUB_TOKEN), secret=GITHUB_SECRET, events=events)
    GitHub.run(listener, host=IPv4(http_ip), port=http_port)
end

function get_commit(event::WebhookEvent)
    kind = event.kind
    payload = event.payload
    if kind == "push"
        commit = payload["after"]
    elseif kind == "pull_request"
        commit = payload["pull_request"]["head"]["sha"]
    elseif kind == "status"
        commit = payload["commit"]["sha"]
    end
    commit
end

event_queue = Queue(WebhookEvent)

"""
The webhook handler.
"""
function event_handler(event::WebhookEvent)
    global event_queue
    kind, payload, repo = event.kind, event.payload, event.repository

    if kind == "pull_request" && payload["action"] == "closed" && payload["pull_request"]["merged"]
        commit = get_commit(event)
        info("Creating registration pull request for $commit")
        enqueue!(event_queue, (event, :register))

    elseif kind == "ping" || kind == "pull_request" && payload["action"] == "closed"

        info("Received event $kind, nothing to do")
        return HTTP.Messages.Response(200)

    elseif kind in ["pull_request", "push"] &&
       payload["action"] in ["opened", "reopened", "synchronize"]

        commit = get_commit(event)
        info("Enqueueing CI for $commit")
        enqueue!(event_queue, (event, :ci))

        if !DEV_MODE
            params = Dict("state" => "pending",
                          "context" => GITHUB_USER,
                          "description" => "pending")
            GitHub.create_status(repo, commit;
                                 auth=GitHub.authenticate(GITHUB_TOKEN),
                                 params=params)
        end
    end

    return HTTP.Messages.Response(200)
end

get_prid(event) = event.payload["pull_request"]["number"]
get_reponame(event) = get(event.repository.full_name)

is_pr_open(repo::String, prid::Int) =
    get(pull_request(Repo(repo), prid; auth=GitHub.authenticate(GITHUB_TOKEN)).state) == "open"

is_pr_open(event::WebhookEvent) =
    is_pr_open(get_reponame(event), get_prid(event))

function recover(f)
    while true
        try
            f()
        catch ex
            info("Task $f failed")
            info(get_backtrace(ex))
        end

        sleep(CYCLE_INTERVAL)
    end
end

macro recover(e)
    :(recover(() -> $(esc(e)) ))
end

function handle_ci_events(event)
    commit = get_commit(event)

    if !is_pr_open(event)
        continue
    end

    info("Processing CI event for commit: $commit")

    # DO CI HERE

    # CI results
    text_table = ""
    success = false

    if !DEV_MODE
        headers = Dict("private_token" => GITHUB_TOKEN)
        params = Dict("body" => text_table)
        repo = event.repository
        auth = GitHub.authenticate(GITHUB_TOKEN)
        GitHub.create_comment(repo, event.payload["pull_request"]["number"],
                              :issue; headers=headers,
                              params=params, auth=auth)

        params = Dict("state" => success ? "success" : "error",
                      "context" => GITHUB_USER,
                      "description" => "done")
        GitHub.create_status(repo, commit;
                             auth=auth,
                             params=params)
    else
        println(text_table)
    end

    info("Done processing event for commit: $commit")
end

function handle_ci_events(event)
    commit = get_commit(event)

    info("Processing Register event for commit: $commit")

    Registrator.register(event.repository["clone_url"], commit; registry=REGISTRY, push=true)

    info("Done processing event for commit: $commit")
end

function tester()
    global event_queue
    cd(work_dir)

    while true
        while !isempty(event_queue)
            event, t = dequeue!(event_queue)
            if t == :ci
                handle_ci_events(event)
            elseif t == :register
                handle_register_events(event)
            end
        end

        sleep(CYCLE_INTERVAL)
    end
end

function main()
    @schedule @recover tester()
    @recover start_github_webhook()
end

end    # module
