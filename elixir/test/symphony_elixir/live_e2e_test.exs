defmodule SymphonyElixir.LiveE2ETest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.{Commands, History, Projection, Sync, Writer}
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.DeterministicMerge.Worker, as: MergeWorker
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Workflow.Store
  alias SymphonyElixir.Worktree

  @moduletag :live
  @acknowledged_timeout 600_000

  @tag timeout: @acknowledged_timeout
  test "disposable board and source remotes survive implementation, review, rework, merge, cleanup, and replay" do
    unless System.get_env("SYMPHONY_RUN_LIVE_E2E") == "1" do
      flunk("set SYMPHONY_RUN_LIVE_E2E=1 to run the Git-backed Kanban live test")
    end

    original_path = System.get_env("PATH")
    original_state = System.get_env("FAKE_GH_STATE")
    original_workflow = Workflow.workflow_file_path()
    fixture = configure_fixture(original_path)

    on_exit(fn ->
      restore_env("PATH", original_path)
      restore_env("FAKE_GH_STATE", original_state)
      Workflow.set_workflow_file_path(original_workflow)
      Store.force_reload()
    end)

    Workflow.set_workflow_file_path(fixture.source.workflow)
    assert :ok = Store.force_reload()
    assert {:ok, %{source: %{root: source_root}, board: %{remote: board_remote}}} = Workflow.current()
    assert source_root == fixture.source.root
    assert board_remote == fixture.board_remote

    eventually(fn -> Sync.status()[:state] not in [:unknown, :not_started, :local_only] end)

    {backlog, _key} =
      BoardFactory.create_task(%{
        title: "Exercise the complete Git-backed workflow",
        brief: "Create a substantive source change and carry it through every standard automated stage.",
        acceptance_criteria: ["The source change is committed, reviewed, merged, and replayable."]
      })

    {todo, _result} = BoardFactory.move(backlog, "todo")

    implementation = run_stage(todo, "automated_review")
    worktree = Worktree.path(implementation)
    assert File.regular?(Path.join(worktree, "lib/live_e2e.ex"))
    assert implementation.github["number"] == 1
    assert implementation.github["draft"] == true
    assert implementation.github["url"] == "https://github.test/owner/repo/pull/1"

    first_human_review = run_stage(implementation, "human_review")
    assert get_in(first_human_review.github, ["ready", "completed"]) == true
    assert first_human_review.github["draft"] == false
    assert comment_count(fixture.gh_state) == 1
    refute File.exists?(Path.join(fixture.gh_state, "draft"))

    assert {:ok, %{"task" => rework_pending}} =
             Board.execute(
               %Commands.SubmitFeedback{task_id: first_human_review.id, feedback: "Address the live review findings"},
               actor: %{type: :human, identity: "board-ui"},
               expected_revision: first_human_review.revision,
               idempotency_key: BoardFactory.unique("live-feedback")
             )

    eventually(fn ->
      File.regular?(Path.join(fixture.gh_state, "draft")) and
        match?(
          {:ok, %{github: %{"draft" => true, "rework_draft" => %{"completed" => true}}}},
          Board.task(rework_pending["id"])
        )
    end)

    assert {:ok, rework} = Board.task(rework_pending["id"])
    draft_review = run_stage(rework, "automated_review")
    second_human_review = run_stage(draft_review, "human_review")

    assert comment_count(fixture.gh_state) == 2
    refute File.exists?(Path.join(fixture.gh_state, "draft"))
    assert second_human_review.github["draft"] == false

    orchestrator = Process.whereis(Orchestrator)
    assert is_pid(orchestrator)
    original_dispatch_enabled = :sys.get_state(orchestrator).dispatch_enabled

    on_exit(fn -> restore_dispatch(orchestrator, original_dispatch_enabled) end)

    :ok = :sys.suspend(orchestrator)

    merging =
      try do
        {ready_review, _result} =
          BoardFactory.move(Task.to_map(second_human_review), "automated_review")

        merging = run_stage(ready_review, "merging")
        assert merging.review_attestation["verdict"] == "pass"
        assert merging.review_attestation["reviewed_head_sha"] == merging.source["head_sha"]
        assert :none = MergeWorker.active()

        merge_runs = Board.runs(merging.id)
        assert length(merge_runs) == 5
        refute Enum.any?(merge_runs, &(&1["start_column_id"] == "merging" or &1["stage_id"] == "merging"))
        merging
      after
        :ok = :sys.resume(orchestrator)
      end

    enable_system_dispatch(orchestrator)
    reviewed_head = merging.review_attestation["reviewed_head_sha"]

    eventually(fn ->
      case Board.task(merging.id) do
        {:ok, task} -> task.column_id == "done"
        _ -> false
      end
    end)

    assert {:ok, done} = Board.task(merging.id)

    assert get_in(done.github, ["merged", "merged"]) == true
    assert get_in(done.github, ["merged", "merge_reachable"]) == true
    assert File.regular?(Path.join(fixture.gh_state, "readiness_ran"))
    assert File.read!(Path.join(fixture.gh_state, "guarded_head")) == reviewed_head

    merge_sha = get_in(done.github, ["merged", "merge_sha"])
    target_head = BoardFactory.git!(fixture.source.remote, ["rev-parse", "refs/heads/main"]) |> String.trim()
    assert target_head == merge_sha

    assert {_output, 0} =
             System.cmd(
               "git",
               ["--git-dir", fixture.source.remote, "diff", "--quiet", "#{reviewed_head}^{tree}", "#{merge_sha}^{tree}"],
               stderr_to_stdout: true
             )

    eventually(fn ->
      done.id
      |> Board.runs()
      |> Enum.count(&is_map(&1["stats_publication"]))
      |> Kernel.==(4)
    end)

    runs = Board.runs(done.id)
    assert length(runs) == 5
    assert Enum.all?(runs, &(get_in(&1, ["stats", "turn_count"]) == 1))
    assert Enum.all?(runs, &(get_in(&1, ["stats", "token_usage", "total_tokens"]) == 1_250))
    assert Enum.count(runs, &(get_in(&1, ["stats_publication", "destination"]) == "pr_body")) == 1
    assert Enum.count(runs, &(get_in(&1, ["stats_publication", "destination"]) == "workpad_comment")) == 3
    assert Enum.count(runs, &is_nil(&1["stats_publication"])) == 1

    eventually(fn -> not File.exists?(worktree) end)
    assert {:ok, _checkpoint} = Board.handoff()
    assert :ok = History.verify_remote("symphony", fixture.board_remote)

    snapshot = Task.to_map(done)
    event_types = Board.events(done.id) |> Enum.map(& &1["type"])
    assert "pull_request_linked" in event_types
    assert "github_ready_recorded" in event_types
    assert "deterministic_merge_completed" in event_types
    refute "github_merged_recorded" in event_types
    assert "task_transitioned" in event_types
    assert "run_finished" in event_types

    assert :ok = Projection.rebuild([])
    assert {:error, :not_found} = Board.task(done.id)

    previous_writer = Process.whereis(Writer)
    Process.exit(previous_writer, :kill)
    eventually(fn -> is_pid(Process.whereis(Writer)) and Process.whereis(Writer) != previous_writer end)

    eventually(fn ->
      case Board.task(done.id) do
        {:ok, task} -> task.column_id == "done" and task.revision == snapshot["revision"]
        {:error, :not_found} -> false
      end
    end)

    assert {:ok, replayed} = Board.task(done.id)
    assert Task.to_map(replayed) == snapshot
  end

  defp configure_fixture(original_path) do
    root = Path.join(System.tmp_dir!(), BoardFactory.unique("git-kanban-live"))
    gh_bin = Path.join(root, "bin")
    gh_state = Path.join(root, "gh-state")
    fake_codex = Path.join(root, "fake_codex.exs")
    board_remote = Path.join(root, "board.git")
    File.mkdir_p!(gh_bin)
    File.mkdir_p!(gh_state)
    File.write!(Path.join(gh_state, "comments_count"), "0\n")
    File.write!(Path.join(gh_bin, "gh"), fake_gh_script())
    File.chmod!(Path.join(gh_bin, "gh"), 0o755)
    File.write!(fake_codex, fake_codex_script())

    source = BoardFactory.workflow_source()
    readiness_script = Path.join(source.root, "merge-readiness.sh")

    File.write!(
      readiness_script,
      "#!/bin/sh\nset -eu\n: > \"${FAKE_GH_STATE:?}/readiness_ran\"\n"
    )

    File.chmod!(readiness_script, 0o755)
    BoardFactory.git!(source.root, ["add", "merge-readiness.sh"])

    BoardFactory.git!(source.root, [
      "-c",
      "user.name=Symphony Live E2E",
      "-c",
      "user.email=symphony-live@example.com",
      "commit",
      "-m",
      "add deterministic readiness fixture"
    ])

    BoardFactory.git!(source.root, ["push", "origin", "main"])
    github_url = "https://github.test/owner/repo.git"
    rewrite_key = "url.file://#{source.remote}.insteadOf"
    BoardFactory.git!(source.root, ["config", rewrite_key, github_url])
    BoardFactory.git!(source.root, ["remote", "set-url", "origin", github_url])
    BoardFactory.git!(source.root, ["ls-remote", "origin", "refs/heads/main"])

    {_output, 0} =
      System.cmd("git", ["init", "--bare", "--initial-branch=main", board_remote], stderr_to_stdout: true)

    codex_command =
      "cd #{shell_escape(File.cwd!())} && mise exec -- mix run --no-start #{shell_escape(fake_codex)}"

    workflow =
      source.workflow
      |> File.read!()
      |> then(&Regex.replace(~r/^  command:.*$/m, &1, "  command: #{Jason.encode!(codex_command)}"))
      |> then(&Regex.replace(~r/^  readiness_command:.*$/m, &1, "  readiness_command: ./merge-readiness.sh"))
      |> then(
        &Regex.replace(
          ~r/^board:\n  remote:.*$/m,
          &1,
          "board:\n  remote: #{Jason.encode!(board_remote)}"
        )
      )

    File.write!(source.workflow, workflow)

    System.put_env("PATH", gh_bin <> ":" <> original_path)
    System.put_env("FAKE_GH_STATE", gh_state)

    %{root: root, source: source, gh_state: gh_state, board_remote: board_remote}
  end

  defp run_stage(task, expected_column) do
    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: task_id(task)},
               actor: %{type: :system, identity: "live-e2e"},
               expected_revision: task_revision(task),
               idempotency_key: BoardFactory.unique("live-claim")
             )

    assert claimed["runtime_state"] == "starting"
    assert :ok = AgentRunner.run(claimed["id"], run["id"])
    assert {:ok, updated} = Board.task(claimed["id"])
    assert updated.column_id == expected_column
    assert updated.active_run_id == nil
    assert updated.runtime_state == nil
    updated
  end

  defp task_id(%Task{id: id}), do: id
  defp task_id(%{"id" => id}), do: id
  defp task_revision(%Task{revision: revision}), do: revision
  defp task_revision(%{"revision" => revision}), do: revision

  defp comment_count(root) do
    root
    |> Path.join("comments_count")
    |> File.read!()
    |> String.trim()
    |> String.to_integer()
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(50)
      eventually(predicate, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp enable_system_dispatch(orchestrator) do
    :sys.replace_state(orchestrator, &%{&1 | dispatch_enabled: true})
    Orchestrator.refresh()
  end

  defp restore_dispatch(orchestrator, dispatch_enabled) do
    if Process.alive?(orchestrator) do
      :sys.replace_state(orchestrator, &%{&1 | dispatch_enabled: dispatch_enabled})
    end
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp fake_gh_script do
    ~S"""
    #!/bin/sh
    set -eu
    state=${FAKE_GH_STATE:?}
    mkdir -p "$state"

    head_oid() { git rev-parse HEAD; }
    draft_value() { if [ -f "$state/draft" ]; then printf 'true'; else printf 'false'; fi; }
    pr_state() { if [ -f "$state/merged" ]; then printf 'MERGED'; elif [ -f "$state/closed" ]; then printf 'CLOSED'; else printf 'OPEN'; fi; }

    case "${1:-}" in
      auth)
        exit 0
        ;;
      repo)
        printf '%s' '{"nameWithOwner":"owner/repo"}'
        ;;
      api)
        case "$*" in
          *rate_limit*) printf '%s' '{}' ;;
          *graphql*) printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}' ;;
          *issues/comments/*)
            comment_id=""
            body_file=""
            for argument in "$@"; do
              case "$argument" in
                repos/*/issues/comments/*) comment_id=${argument##*/} ;;
                body=@*) body_file=${argument#body=@} ;;
              esac
            done
            cp "$body_file" "$state/comment_$comment_id"
            printf '%s' '{}'
            ;;
          *issues/*/comments*)
            count=$(cat "$state/comments_count")
            printf '['
            index=1
            while [ "$index" -le "$count" ]; do
              if [ "$index" -gt 1 ]; then printf ','; fi
              markers=$(grep -o '<!-- symphony-[^>]* -->' "$state/comment_$index" | tr '\n' ' ')
              printf '{"id":%s,"body":"%s"}' "$index" "$markers"
              index=$((index + 1))
            done
            printf ']'
            ;;
          *) printf '%s' '{}' ;;
        esac
        ;;
      pr)
        case "${2:-}" in
          list)
            if [ -f "$state/pr_created" ]; then
              markers=$(grep -o '<!-- symphony-[^>]* -->' "$state/pr_body" | tr '\n' ' ')
              printf '[{"number":1,"url":"https://github.test/owner/repo/pull/1","isDraft":%s,"headRefOid":"%s","state":"%s","body":"%s"}]' "$(draft_value)" "$(head_oid)" "$(pr_state)" "$markers"
            else
              printf '%s' '[]'
            fi
            ;;
          create)
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--body-file" ]; then cp "$argument" "$state/pr_body"; fi
              previous="$argument"
            done
            : > "$state/pr_created"
            : > "$state/draft"
            printf '%s\n' 'https://github.test/owner/repo/pull/1'
            ;;
          edit)
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--body-file" ]; then cp "$argument" "$state/pr_body"; fi
              previous="$argument"
            done
            ;;
          merge)
            match_head=""
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--match-head-commit" ]; then match_head="$argument"; fi
              previous="$argument"
            done
            reviewed_head=$(head_oid)
            if [ "$match_head" != "$reviewed_head" ]; then
              printf '%s\n' "head commit mismatch" >&2
              exit 1
            fi
            git fetch origin main
            target_head=$(git rev-parse origin/main)
            reviewed_tree=$(git rev-parse "$reviewed_head^{tree}")
            merge_sha=$(
              printf '%s\n' 'squash live E2E' |
                GIT_AUTHOR_NAME='Symphony Live E2E' \
                GIT_AUTHOR_EMAIL='symphony-live@example.com' \
                GIT_COMMITTER_NAME='Symphony Live E2E' \
                GIT_COMMITTER_EMAIL='symphony-live@example.com' \
                git commit-tree "$reviewed_tree" -p "$target_head"
            )
            git push origin "$merge_sha:refs/heads/main"
            printf '%s' "$reviewed_head" > "$state/guarded_head"
            printf '%s\n' "$merge_sha" > "$state/merge_sha"
            : > "$state/merged"
            ;;
          view)
            case "$*" in
              *statusCheckRollup*)
                if [ -f "$state/merge_sha" ]; then
                  merge_commit=$(printf '{"oid":"%s"}' "$(cat "$state/merge_sha")")
                else
                  merge_commit=null
                fi
                printf '{"number":1,"url":"https://github.test/owner/repo/pull/1","isDraft":%s,"headRefOid":"%s","state":"%s","reviewDecision":"APPROVED","statusCheckRollup":[],"mergeCommit":%s}' "$(draft_value)" "$(head_oid)" "$(pr_state)" "$merge_commit"
                ;;
              *--json\ body*)
                markers=$(grep -o '<!-- symphony-[^>]* -->' "$state/pr_body" | tr '\n' ' ')
                printf '{"body":"%s"}' "$markers"
                ;;
              *mergeCommit*)
                merge_sha=$(cat "$state/merge_sha")
                printf '{"number":1,"url":"https://github.test/owner/repo/pull/1","headRefOid":"%s","state":"MERGED","mergeCommit":{"oid":"%s"}}' "$(head_oid)" "$merge_sha"
                ;;
              *)
                printf '{"number":1,"url":"https://github.test/owner/repo/pull/1","isDraft":%s,"headRefOid":"%s","state":"%s"}' "$(draft_value)" "$(head_oid)" "$(pr_state)"
                ;;
            esac
            ;;
          checks)
            printf '%s' '[]'
            ;;
          ready)
            if [ "${3:-}" = "--undo" ]; then : > "$state/draft"; else rm -f "$state/draft"; fi
            ;;
          comment)
            count=$(cat "$state/comments_count")
            count=$((count + 1))
            printf '%s\n' "$count" > "$state/comments_count"
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--body-file" ]; then cp "$argument" "$state/comment_$count"; fi
              previous="$argument"
            done
            ;;
          close)
            : > "$state/closed"
            ;;
          *)
            printf '%s\n' "unsupported fake gh pr command: $*" >&2
            exit 2
            ;;
        esac
        ;;
      *)
        printf '%s\n' "unsupported fake gh command: $*" >&2
        exit 2
        ;;
    esac
    """
  end

  defp fake_codex_script do
    ~S"""
    defmodule SymphonyLiveFakeCodex do
      def main, do: loop(%{})

      defp loop(state) do
        case IO.read(:stdio, :line) do
          :eof ->
            :ok

          line ->
            message = Jason.decode!(line)
            {next, outgoing} = handle(message, state)
            outgoing |> List.wrap() |> Enum.each(&IO.puts(Jason.encode!(&1)))
            loop(next)
        end
      end

      defp handle(%{"method" => "initialize", "id" => id}, state) do
        {state, %{"id" => id, "result" => %{}}}
      end

      defp handle(%{"method" => "initialized"}, state), do: {state, []}

      defp handle(%{"method" => "model/list", "id" => id}, state) do
        {state, %{"id" => id, "result" => %{"data" => [%{"model" => "gpt-5.5"}]}}}
      end

      defp handle(%{"method" => "thread/start", "id" => id, "params" => params}, state) do
        thread = "fake-thread-#{System.system_time(:nanosecond)}"

        {Map.merge(state, %{cwd: params["cwd"], thread: thread}),
         %{"id" => id, "result" => %{"thread" => %{"id" => thread}}}}
      end

      defp handle(%{"method" => "turn/start", "id" => id, "params" => params}, state) do
        prompt = get_in(params, ["input", Access.at(0), "text"])
        [_, stage] = Regex.run(~r/Stage: ([^\n]+)/, prompt)
        turn = "fake-turn-#{System.system_time(:nanosecond)}"
        context_id = "#{turn}:context"

        next = Map.merge(state, %{stage: stage, turn: turn, phase: :initial_context})

        {next,
         [
           %{"id" => id, "result" => %{"turn" => %{"id" => turn}}},
           tool_call(context_id, "symphony_task_context", %{})
         ]}
      end

      defp handle(%{"id" => _id, "result" => result}, %{phase: :initial_context} = state) do
        payload = successful_output!(result)
        task = payload["task"]
        apply_source_effect(state.stage, state.cwd)
        run_id = payload["run"]["id"]

        next = Map.merge(state, %{phase: :workpad, task: task, run_id: run_id})
        args = %{"content" => "#{state.stage} workpad for #{task["identifier"]}"}
        {next, tool_call("#{run_id}:workpad", "symphony_workpad_write", args)}
      end

      defp handle(%{"id" => _id, "result" => result}, %{phase: :workpad} = state) do
        successful_output!(result)
        context_id = "#{state.run_id}:refreshed-context"
        {%{state | phase: :refreshed_context}, tool_call(context_id, "symphony_task_context", %{})}
      end

      defp handle(%{"id" => _id, "result" => result}, %{phase: :refreshed_context} = state) do
        payload = successful_output!(result)
        task = payload["task"]

        cond do
          state.stage == "implementation" ->
            criterion = hd(payload["criteria"])

            args = %{
              "criterion_id" => criterion["id"],
              "evidence" => [%{"command" => "fake live validation", "result" => "passed"}],
              "expected_revision" => task["revision"]
            }

            {%{state | phase: :acceptance},
             tool_call("#{state.run_id}:acceptance", "symphony_acceptance_complete", args)}

          state.stage == "automated_review" and get_in(payload, ["github", "draft"]) == true ->
            transition(state, task["revision"])

          state.stage == "automated_review" ->
            review_complete(state, task, payload["source"]["head_sha"])

          true ->
            transition(state, task["revision"])
        end
      end

      defp handle(%{"id" => _id, "result" => result}, %{phase: :acceptance} = state) do
        task = successful_output!(result)["task"]
        transition(state, task["revision"])
      end

      defp handle(%{"id" => _id, "result" => result}, %{phase: phase} = state)
           when phase in [:transition, :review] do
        successful_output!(result)

        usage = %{
          "method" => "thread/tokenUsage/updated",
          "params" => %{
            "tokenUsage" => %{
              "total" => %{
                "inputTokens" => 1_000,
                "cachedInputTokens" => 700,
                "outputTokens" => 250,
                "totalTokens" => 1_250
              }
            }
          }
        }

        completed = %{
          "method" => "turn/completed",
          "params" => %{"turn" => %{"id" => state.turn, "status" => "completed"}}
        }

        {%{state | phase: :completed}, [usage, completed]}
      end

      defp handle(_message, state), do: {state, []}

      defp transition(state, revision) do
        target =
          Map.fetch!(
            %{
              "implementation" => "automated_review",
              "automated_review" => "human_review",
              "rework" => "automated_review"
            },
            state.stage
          )

        args = %{"column_id" => target, "expected_revision" => revision}
        {%{state | phase: :transition}, tool_call("#{state.run_id}:transition", "symphony_task_transition", args)}
      end

      defp review_complete(state, task, reviewed_head) do
        args = %{
          "expected_revision" => task["revision"],
          "verdict" => "pass",
          "reviewed_head_sha" => reviewed_head,
          "route" => "merging",
          "plan_policy" => %{
            "status" => "followed",
            "summary" => "The live fixture followed the repository plan policy."
          },
          "validation_evidence" => [
            %{"command" => "fake live validation", "result" => "passed", "exit_status" => 0}
          ],
          "findings" => []
        }

        {%{state | phase: :review},
         tool_call("#{state.run_id}:review", "symphony_review_complete", args)}
      end

      defp tool_call(id, tool, arguments) do
        %{"id" => id, "method" => "item/tool/call", "params" => %{"tool" => tool, "arguments" => arguments}}
      end

      defp successful_output!(%{"success" => true, "output" => output}), do: Jason.decode!(output)
      defp successful_output!(result), do: raise("fake Codex tool failed: #{inspect(result)}")

      defp apply_source_effect("implementation", cwd), do: commit_change(cwd, 1, "implementation")
      defp apply_source_effect("rework", cwd), do: commit_change(cwd, 2, "rework")
      defp apply_source_effect(_stage, _cwd), do: :ok

      defp commit_change(cwd, value, message) do
        path = Path.join(cwd, "lib/live_e2e.ex")
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "defmodule LiveE2E do\n  def value, do: #{value}\nend\n")
        git!(cwd, ["config", "user.name", "Symphony Live E2E"])
        git!(cwd, ["config", "user.email", "symphony-live@example.com"])
        git!(cwd, ["add", "lib/live_e2e.ex"])
        git!(cwd, ["commit", "-m", message])
      end

      defp git!(cwd, args) do
        case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
          {output, 0} -> String.trim(output)
          {output, status} -> raise("git failed #{status}: #{output}")
        end
      end
    end

    SymphonyLiveFakeCodex.main()
    """
  end
end
