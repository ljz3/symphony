defmodule SymphonyElixir.GitHubClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board
  alias SymphonyElixir.Board.{Commands, Projection}
  alias SymphonyElixir.BoardFactory
  alias SymphonyElixir.GitHub
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Task
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.Worktree

  setup do
    root = Path.join(System.tmp_dir!(), "fake-gh-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "pr_edit_count"), "0\n")
    File.write!(Path.join(root, "comment_patch_count"), "0\n")
    File.write!(Path.join(root, "comment_count"), "0\n")
    File.write!(Path.join(root, "review_comment_page_count"), "0\n")
    executable = Path.join(root, "gh")

    File.write!(executable, """
    #!/bin/sh
    state="${FAKE_GH_STATE}"

    increment() {
      count=$(cat "$1")
      count=$((count + 1))
      printf '%s\n' "$count" > "$1"
    }

    case "$1" in
      json)
        printf '%s' '{"ok":true}'
        ;;
      accepted)
        printf '%s' 'accepted'
        exit 8
        ;;
      auth)
        printf '%s' 'authenticated'
        ;;
      repo)
        printf '%s' '{"nameWithOwner":"example/repository"}'
        ;;
      api)
        case "$*" in
          *rate_limit*) printf '%s' '{"resources":{}}' ;;
          *graphql*)
            if [ "${FAKE_GH_REVIEW_PAGINATION:-}" = "comments-101" ]; then
              case "$*" in
                *id=thread-1*)
                  increment "$state/review_comment_page_count"
                  case "$*" in
                    *after=comments-page-2*) cat "$state/review_comments_page_2.json" ;;
                    *) cat "$state/review_comments_page_1.json" ;;
                  esac
                  ;;
                *) cat "$state/review_threads_page.json" ;;
              esac
            else
              printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
            fi
            ;;
          *issues/comments/*)
            previous=""
            for argument in "$@"; do
              case "$argument" in
                body=@*) cp "${argument#body=@}" "$state/comment_body" ;;
              esac
              previous="$argument"
            done
            increment "$state/comment_patch_count"
            printf '%s' '{}'
            ;;
          *issues/*/comments*)
            if [ -f "$state/comment_marker" ]; then
              marker=$(cat "$state/comment_marker")
              if [ -f "$state/comment_body" ]; then
                printf '[{"id":123,"body":"%s<!-- symphony-run-stats:%s -->"}]' "$marker" "$FAKE_RUN_ID"
              else
                printf '[{"id":123,"body":"%s"}]' "$marker"
              fi
            elif [ -n "$FAKE_PUBLICATION_ID" ]; then
              if [ -f "$state/comment_body" ]; then
                printf '[{"id":123,"body":"<!-- symphony-workpad-publication:%s --><!-- symphony-run-stats:%s -->"}]' "$FAKE_PUBLICATION_ID" "$FAKE_RUN_ID"
              else
                printf '[{"id":123,"body":"<!-- symphony-workpad-publication:%s -->"}]' "$FAKE_PUBLICATION_ID"
              fi
            else
              printf '%s' '[]'
            fi
            ;;
          *) printf '%s' 'unsupported api command'; exit 7 ;;
        esac
        ;;
      pr)
        case "$2" in
          checks)
            case "${FAKE_GH_CHECKS:-green}" in
              none) printf '%s\n' "no required checks reported on the 'feature/TEST' branch"; exit 1 ;;
              green) printf '%s' '[{"name":"required","state":"SUCCESS","workflow":"CI","bucket":"pass"}]' ;;
              failed) printf '%s' '[{"name":"required","state":"FAILURE","workflow":"CI","bucket":"fail"}]'; exit 1 ;;
              pending) printf '%s' '[{"name":"required","state":"PENDING","workflow":"CI","bucket":"pending"}]'; exit 8 ;;
              malformed) printf '%s' 'not-json' ;;
              cli_failure) printf '%s' 'transport failure'; exit 7 ;;
            esac
            ;;
          list)
            printf '%s' '[]'
            ;;
          create)
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--body-file" ]; then
                cp "$argument" "$state/created_pr_body"
              fi
              previous="$argument"
            done
            printf '%s\n' 'https://github.example/example/repository/pull/42'
            ;;
          edit)
            if [ -f "$state/fail_pr_edit_once" ] && [ ! -f "$state/pr_edit_failed_once" ]; then
              : > "$state/pr_edit_failed_once"
              printf '%s' 'temporary edit failure'
              exit 7
            fi
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--body-file" ]; then
                cp "$argument" "$state/pr_body"
              fi
              previous="$argument"
            done
            increment "$state/pr_edit_count"
            printf '%s' 'edited'
            ;;
          comment)
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--body-file" ]; then
                cp "$argument" "$state/posted_comment_body"
                grep -o '<!-- symphony-workpad-publication:[^>]* -->' "$argument" > "$state/comment_marker"
              fi
              previous="$argument"
            done
            increment "$state/comment_count"
            printf '%s' 'commented'
            ;;
          view)
            case "$*" in
              *"--json body"*)
                if [ -f "$state/pr_body" ]; then
                  printf '{"body":"<!-- symphony-run-stats:%s -->"}' "$FAKE_RUN_ID"
                else
                  printf '%s' '{"body":"Original body"}'
                fi
                ;;
              *)
                head="$(git rev-parse HEAD)"
                review_decision="${FAKE_GH_REVIEW_DECISION:-}"
                draft_value="${FAKE_GH_DRAFT_VALUE:-true}"
                printf '%s' "$*" > "$state/last_pr_view_args"
                printf '{"number":42,"url":"https://github.example/example/repository/pull/42","isDraft":%s,"headRefOid":"%s","reviewDecision":"%s","state":"OPEN","statusCheckRollup":[]}' "$draft_value" "$head" "$review_decision"
                ;;
            esac
            ;;
          *)
            printf '%s' 'unsupported pr command'
            exit 7
            ;;
        esac
        ;;
      *)
        printf '%s' 'failure'
        exit 7
        ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    old_path = System.get_env("PATH")
    System.put_env("PATH", root <> ":" <> old_path)
    System.put_env("FAKE_GH_STATE", root)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      System.delete_env("FAKE_GH_CHECKS")
      System.delete_env("FAKE_GH_REVIEW_PAGINATION")
      System.delete_env("FAKE_GH_REVIEW_DECISION")
      System.delete_env("FAKE_GH_DRAFT_VALUE")
      System.delete_env("FAKE_GH_STATE")
      System.delete_env("FAKE_PUBLICATION_ID")
      System.delete_env("FAKE_RUN_ID")
      File.rm_rf!(root)
    end)

    %{fake_gh_root: root}
  end

  test "returns output, parses JSON, and reports non-accepted statuses" do
    assert {:ok, %{"ok" => true}} = Client.json(["json"])
    assert {:ok, "accepted"} = Client.run(["accepted"], accepted_statuses: [8])
    assert {:error, {:gh_failed, ["failure"], 7, "failure"}} = Client.run(["failure"])
  end

  test "treats the exact no-required-checks diagnostic as an empty green set" do
    assert {:ok, readiness} = readiness("none")
    assert readiness.required_checks == []
    assert readiness.required_checks_green
  end

  test "keeps all green required checks green" do
    assert {:ok, readiness} = readiness("green")
    assert [%{"state" => "SUCCESS", "bucket" => "pass"}] = readiness.required_checks
    assert readiness.required_checks_green
  end

  test "keeps failed required checks blocking" do
    assert {:ok, readiness} = readiness("failed")
    assert [%{"state" => "FAILURE", "bucket" => "fail"}] = readiness.required_checks
    refute readiness.required_checks_green
  end

  test "keeps pending required checks blocking" do
    assert {:ok, readiness} = readiness("pending")
    assert [%{"state" => "PENDING", "bucket" => "pending"}] = readiness.required_checks
    refute readiness.required_checks_green
  end

  test "rejects malformed required-check output" do
    assert {:error, {:gh_invalid_json, ["pr", "checks", "42" | _rest], %Jason.DecodeError{}}} =
             readiness("malformed")
  end

  test "preserves genuine required-check CLI failures" do
    assert {:error, {:gh_failed, ["pr", "checks", "42" | _rest], 7, "transport failure"}} =
             readiness("cli_failure")
  end

  test "review snapshot fingerprints comments beyond the first hundred", %{fake_gh_root: root} do
    source = BoardFactory.workflow_source()
    System.put_env("FAKE_GH_REVIEW_PAGINATION", "comments-101")

    File.write!(
      Path.join(root, "review_threads_page.json"),
      Jason.encode!(%{
        "data" => %{
          "repository" => %{
            "pullRequest" => %{
              "reviewThreads" => %{
                "nodes" => [%{"id" => "thread-1", "isResolved" => false}],
                "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
              }
            }
          }
        }
      })
    )

    first_hundred =
      Enum.map(1..100, fn index ->
        %{"id" => "comment-#{index}", "updatedAt" => "2026-07-16T00:00:00Z"}
      end)

    write_review_comment_pages(root, first_hundred, "2026-07-16T00:00:00Z")
    task = task_fixture("TEST", github: %{"number" => 42})

    assert {:ok, first} = GitHub.review_snapshot(task, source.root)
    assert first.unresolved_review_threads == 1
    assert file_count(root, "review_comment_page_count") == 2

    write_review_comment_pages(root, first_hundred, "2026-07-16T00:00:01Z")
    assert {:ok, second} = GitHub.review_snapshot(task, source.root)
    assert file_count(root, "review_comment_page_count") == 4
    refute second.feedback_fingerprint == first.feedback_fingerprint
  end

  test "review snapshot accepts only GitHub's aggregate approved decision" do
    source = BoardFactory.workflow_source()
    task = task_fixture("TEST", github: %{"number" => 42})

    for {decision, expected} <- [{"", false}, {"CHANGES_REQUESTED", false}, {"APPROVED", true}] do
      System.put_env("FAKE_GH_REVIEW_DECISION", decision)
      assert {:ok, %{approved: ^expected}} = GitHub.review_snapshot(task, source.root)
    end
  end

  test "review snapshot requests and fingerprints one bounded draft boolean", %{fake_gh_root: root} do
    source = BoardFactory.workflow_source()
    task = task_fixture("TEST", github: %{"number" => 42})

    System.put_env("FAKE_GH_DRAFT_VALUE", "true")
    assert {:ok, first} = GitHub.review_snapshot(task, source.root)
    assert first.draft == true
    assert File.read!(Path.join(root, "last_pr_view_args")) =~ "isDraft"

    assert Map.keys(first) |> Enum.sort() ==
             ~w(approved checks_fingerprint draft feedback_fingerprint head_sha merge_sha mergeable number observed_at required_checks_green source_head_sha state unresolved_review_threads url)a

    System.put_env("FAKE_GH_DRAFT_VALUE", "false")
    assert {:ok, second} = GitHub.review_snapshot(task, source.root)
    assert second.draft == false
    refute second.feedback_fingerprint == first.feedback_fingerprint

    System.put_env("FAKE_GH_DRAFT_VALUE", Jason.encode!("not-a-boolean"))
    assert {:error, _reason} = GitHub.review_snapshot(task, source.root)
  end

  test "returns the live pull-request identity and source head for conflict verification" do
    source = BoardFactory.workflow_source()
    task = task_fixture("TEST", github: %{"number" => 42})
    expected_head = BoardFactory.git!(source.root, ["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok,
            %{
              "number" => 42,
              "head_sha" => ^expected_head,
              "state" => "OPEN",
              "url" => "https://github.example/example/repository/pull/42"
            }} = GitHub.pull_request_source_snapshot(task, source.root)

    assert {:error, :pull_request_not_linked} =
             GitHub.pull_request_source_snapshot(%{task | github: %{}}, source.root)
  end

  test "creates a draft pull request for committed documentation configuration and tooling changes", %{
    fake_gh_root: fake_gh_root
  } do
    original = Workflow.workflow_file_path()
    source = BoardFactory.workflow_source()
    github_url = "https://github.com/example/repository.git"
    BoardFactory.git!(source.root, ["config", "url.file://#{source.remote}.insteadOf", github_url])
    BoardFactory.git!(source.root, ["remote", "set-url", "origin", github_url])
    :ok = Workflow.set_workflow_file_path(source.workflow)
    assert :ok = Workflow.Store.force_reload()
    BoardFactory.await_activation()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original)
      Workflow.Store.force_reload()
    end)

    task = task_fixture(BoardFactory.unique("SYM-DOCS"))
    assert {:ok, worktree} = Worktree.ensure(task)

    on_exit(fn ->
      if File.exists?(worktree) do
        System.cmd("git", ["-C", source.root, "worktree", "remove", "--force", worktree], stderr_to_stdout: true)
      end

      System.cmd("git", ["-C", source.root, "branch", "-D", task.branch], stderr_to_stdout: true)
    end)

    assert {:ok, false} = GitHub.meaningful_commit?(task, worktree)
    assert {:error, :no_meaningful_committed_diff} = GitHub.ensure_draft_pull_request(task, worktree)

    File.write!(Path.join(source.root, "upstream-only.txt"), "main advanced\n")
    BoardFactory.git!(source.root, ["add", "upstream-only.txt"])
    BoardFactory.git!(source.root, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "advance main"])
    BoardFactory.git!(source.root, ["push", "origin", "main"])
    BoardFactory.git!(source.root, ["fetch", "origin", "main"])

    assert {:ok, false} = GitHub.meaningful_commit?(task, worktree)
    assert {:error, :no_meaningful_committed_diff} = GitHub.ensure_draft_pull_request(task, worktree)

    File.mkdir_p!(Path.join(worktree, "docs/product-specs"))
    File.mkdir_p!(Path.join(worktree, "config"))
    File.mkdir_p!(Path.join(worktree, "scripts"))
    File.write!(Path.join(worktree, "docs/product-specs/task.md"), "# Task\n")
    File.write!(Path.join(worktree, "config/task.yml"), "enabled: true\n")
    File.write!(Path.join(worktree, "scripts/task-check"), "#!/bin/sh\nexit 0\n")
    BoardFactory.git!(worktree, ["add", "."])
    BoardFactory.git!(worktree, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "docs only"])

    creator_run_id = Ecto.UUID.generate()
    assert {:ok, true} = GitHub.meaningful_commit?(task, worktree)

    assert {:ok, %{number: 42, draft: true, state: "open", created_by_run_id: ^creator_run_id}} =
             GitHub.ensure_draft_pull_request(task, worktree, run_id: creator_run_id)

    assert File.read!(Path.join(fake_gh_root, "created_pr_body")) =~
             "<!-- symphony-pr-creator-run:#{creator_run_id} -->"

    assert :ok = Worktree.remove(task)
  end

  test "appends creator-run stats to the PR body exactly once", %{fake_gh_root: root} do
    run = run_fixture(true)
    task = task_fixture("TEST", github: %{"number" => 42})
    System.put_env("FAKE_RUN_ID", run["id"])

    assert {:ok, %{destination: "pr_body", publication_id: publication_id}} =
             GitHub.publish_run_stats(task, run)

    assert {:ok, %{destination: "pr_body", publication_id: ^publication_id}} =
             GitHub.publish_run_stats(task, run)

    assert file_count(root, "pr_edit_count") == 1
    body = File.read!(Path.join(root, "pr_body"))
    assert body =~ "<!-- symphony-run-stats:#{run["id"]} -->"
    assert body =~ "Symphony run stats · Automated review"
    assert body =~ "1m 5s"
    assert body =~ "1,250"
    refute body =~ "thread-secret"
  end

  test "retries a failed PR stats publication and remains marker-idempotent", %{fake_gh_root: root} do
    run = run_fixture(true)
    task = task_fixture("TEST", github: %{"number" => 42})
    System.put_env("FAKE_RUN_ID", run["id"])
    File.touch!(Path.join(root, "fail_pr_edit_once"))

    assert {:error, {:gh_failed, ["pr", "edit", "42" | _rest], 7, "temporary edit failure"}} =
             GitHub.publish_run_stats(task, run)

    assert {:ok, %{destination: "pr_body"}} = GitHub.publish_run_stats(task, run)
    assert {:ok, %{destination: "pr_body"}} = GitHub.publish_run_stats(task, run)
    assert file_count(root, "pr_edit_count") == 1
  end

  test "waits for a workpad publication then patches failed-run stats into that comment once", %{
    fake_gh_root: root
  } do
    run = run_fixture(false, "failed")
    task = task_fixture("TEST", github: %{"number" => 42})
    publication_id = "publication-#{System.unique_integer([:positive])}"

    System.put_env("FAKE_RUN_ID", run["id"])
    System.put_env("FAKE_PUBLICATION_ID", publication_id)

    assert :ok = Projection.write_workpad(run["id"], 1, "failed-run workpad")
    assert {:ok, nil} = GitHub.publish_run_stats(task, run)

    assert :ok =
             Projection.mark_workpads_published(
               [%{run_id: run["id"], invocation: 1}],
               publication_id
             )

    assert {:ok, %{destination: "workpad_comment", publication_id: stats_publication_id}} =
             GitHub.publish_run_stats(task, run)

    assert {:ok, %{destination: "workpad_comment", publication_id: ^stats_publication_id}} =
             GitHub.publish_run_stats(task, run)

    assert file_count(root, "comment_patch_count") == 1
    body = File.read!(Path.join(root, "comment_body"))
    assert body =~ "<!-- symphony-workpad-publication:#{publication_id} -->"
    assert body =~ "<!-- symphony-run-stats:#{run["id"]} -->"
    assert body =~ "| failed |"
    assert body =~ "700"
  end

  test "publication retries bridge the acknowledged-comment crash window and changed content gets a new marker", %{
    fake_gh_root: root
  } do
    {created, _key} = BoardFactory.create_task(%{title: BoardFactory.unique("Publication crash window")})
    {todo, _result} = BoardFactory.move(created, "todo")

    assert {:ok, %{"task" => claimed, "run" => run}} =
             Board.execute(%Commands.ClaimRun{task_id: todo["id"]},
               actor: :system,
               expected_revision: todo["revision"],
               idempotency_key: BoardFactory.unique("publication-claim")
             )

    on_exit(fn -> cleanup_active_run(claimed["id"], run["id"]) end)

    assert :ok = Board.write_workpad(run["id"], 1, "original publication content")
    {:ok, task} = Board.task(claimed["id"])
    task = %{task | github: %{"number" => 42}}

    crash_after_comment = fn _publication_id, _workpads -> {:error, :crash_after_comment} end

    assert {:error, :crash_after_comment} =
             GitHub.publish_workpads(task, File.cwd!(), publication_recorder: crash_after_comment)

    assert file_count(root, "comment_count") == 1
    assert [%{"published" => false}] = Board.workpad_metadata(run["id"])

    assert {:ok, first_publication_id} = GitHub.publish_workpads(task, File.cwd!())
    assert file_count(root, "comment_count") == 1
    assert [%{"published" => true, "publication_id" => ^first_publication_id}] = Board.workpad_metadata(run["id"])

    assert :ok = Board.write_workpad(run["id"], 1, "changed publication content")
    assert [%{"published" => false, "publication_id" => nil}] = Board.workpad_metadata(run["id"])

    assert {:ok, second_publication_id} = GitHub.publish_workpads(task, File.cwd!())
    refute second_publication_id == first_publication_id
    assert file_count(root, "comment_count") == 2
  end

  defp readiness(scenario) do
    System.put_env("FAKE_GH_CHECKS", scenario)
    source = BoardFactory.workflow_source()
    GitHub.readiness(task_fixture("TEST", github: %{"number" => 42}), source.root)
  end

  defp run_fixture(created_pull_request, status \\ "completed") do
    %{
      "id" => Ecto.UUID.generate(),
      "stage_id" => "automated_review",
      "status" => status,
      "model" => "gpt-5.5",
      "effort" => "xhigh",
      "pull_request_created" => created_pull_request,
      "stats" => %{
        "duration_ms" => 65_000,
        "turn_count" => 2,
        "token_usage" => %{
          "input_tokens" => 1_000,
          "cached_input_tokens" => 700,
          "output_tokens" => 250,
          "total_tokens" => 1_250
        }
      }
    }
  end

  defp file_count(root, name) do
    root
    |> Path.join(name)
    |> File.read!()
    |> String.trim()
    |> String.to_integer()
  end

  defp write_review_comment_pages(root, first_hundred, final_updated_at) do
    File.write!(
      Path.join(root, "review_comments_page_1.json"),
      Jason.encode!(%{
        "data" => %{
          "node" => %{
            "comments" => %{
              "nodes" => first_hundred,
              "pageInfo" => %{"hasNextPage" => true, "endCursor" => "comments-page-2"}
            }
          }
        }
      })
    )

    File.write!(
      Path.join(root, "review_comments_page_2.json"),
      Jason.encode!(%{
        "data" => %{
          "node" => %{
            "comments" => %{
              "nodes" => [%{"id" => "comment-101", "updatedAt" => final_updated_at}],
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      })
    )
  end

  defp task_fixture(identifier, opts \\ []) do
    completed = Keyword.get(opts, :completed, true)

    %Task{
      id: Ecto.UUID.generate(),
      identifier: identifier,
      number: System.unique_integer([:positive]),
      project_id: "symphony",
      title: "GitHub task",
      type: :feature,
      branch: "feature/#{identifier}",
      priority: :normal,
      brief: "Brief",
      acceptance_criteria: [
        %{
          "id" => Ecto.UUID.generate(),
          "text" => "Works",
          "completed" => completed,
          "evidence" => if(completed, do: [%{"result" => "passed"}], else: []),
          "evidence_history" => []
        }
      ],
      column_id: "in_progress",
      rank: 1_024,
      revision: 1,
      github: Keyword.get(opts, :github, %{}),
      created_at: "now",
      updated_at: "now"
    }
  end

  defp cleanup_active_run(task_id, run_id) do
    case Board.task(task_id) do
      {:ok, %{active_run_id: ^run_id} = task} ->
        Board.execute(%Commands.RunFailed{task_id: task_id, run_id: run_id, reason: :test_cleanup},
          actor: :system,
          expected_revision: task.revision,
          idempotency_key: BoardFactory.unique("publication-cleanup")
        )

      _ ->
        :ok
    end
  end
end
