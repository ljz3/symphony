defmodule SymphonyElixir.DeterministicMergeSystemBoundaryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Board.Commands
  alias SymphonyElixir.Config
  alias SymphonyElixir.DeterministicMerge
  alias SymphonyElixir.DeterministicMerge.SystemBoundary
  alias SymphonyElixir.Task

  defmodule FakeWorktree do
    def reconcile(_task, _path, _host), do: Process.get(:fake_worktree_reconcile)
    def ensure(_task, _host), do: Process.get(:fake_worktree_ensure)
    def head(_path, _host), do: Process.get(:fake_worktree_head)
  end

  setup do
    fake_root = temporary_directory("fake-merge-gh")
    executable = Path.join(fake_root, "gh")

    File.write!(executable, """
    #!/bin/sh
    set -eu
    state="${FAKE_GH_STATE}"

    case "${1:-}:${2:-}" in
      repo:view)
        printf '%s' '{"nameWithOwner":"example/repository"}'
        ;;
      api:graphql)
        printf '%s' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
        ;;
      pr:checks)
        case "${FAKE_GH_CHECK_MODE:-green}" in
          green) printf '%s' '[{"name":"required","state":"SUCCESS","workflow":"CI","bucket":"pass"}]' ;;
          failed) printf '%s' '[{"name":"required","state":"FAILURE","workflow":"CI","bucket":"fail"}]'; exit 1 ;;
          pending) printf '%s' '[{"name":"required","state":"PENDING","workflow":"CI","bucket":"pending"}]'; exit 8 ;;
          transport) printf '%s' 'transport failure'; exit 7 ;;
          auth) printf '%s' 'authentication unavailable'; exit 7 ;;
          process) printf '%s' 'process unavailable'; exit 7 ;;
        esac
        ;;
      pr:merge)
        printf '%s\n' "$@" > "$state/merge_args"
        case "${FAKE_GH_MERGE_MODE:-merged}" in
          conflict) printf '%s' 'pull request cannot merge due to conflict'; exit 1 ;;
          stale) printf '%s' 'head commit does not match'; exit 1 ;;
          transport) printf '%s' 'network timeout'; exit 1 ;;
          invariant) printf '%s' 'merge policy denied'; exit 1 ;;
          merged) printf '%s' 'merged' ;;
        esac
        ;;
      pr:view)
        case "${FAKE_GH_PR_MODE:-open}" in
          merged)
            printf '{"headRefOid":"%s","mergeCommit":{"oid":"%s"},"state":"MERGED"}' \
              "$FAKE_GH_REVIEWED_HEAD" "$FAKE_GH_MERGE_SHA"
            ;;
          closed)
            printf '{"headRefOid":"%s","mergeCommit":null,"state":"CLOSED"}' "$FAKE_GH_REVIEWED_HEAD"
            ;;
          missing_sha)
            printf '{"headRefOid":"%s","mergeCommit":null,"state":"MERGED"}' "$FAKE_GH_REVIEWED_HEAD"
            ;;
          invalid)
            printf '%s' 'not-json'
            ;;
          open)
            head="$(git rev-parse HEAD)"
            printf '{"number":42,"url":"https://github.example/example/repository/pull/42","isDraft":false,"headRefOid":"%s","mergeCommit":null,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","state":"OPEN","statusCheckRollup":[]}' "$head"
            ;;
        esac
        ;;
      *)
        printf '%s' 'unsupported fake gh command'
        exit 9
        ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    ssh = Path.join(fake_root, "ssh")

    File.write!(ssh, """
    #!/bin/sh
    set -eu
    printf '%s\n' "$@" > "$FAKE_GH_STATE/ssh_args"
    case "${FAKE_SSH_MODE:-success}" in
      success) printf '%s' "${FAKE_SSH_OUTPUT:-remote-output}" ;;
      failed) printf '%s' "${FAKE_SSH_OUTPUT:-remote-failed}"; exit 9 ;;
    esac
    """)

    File.chmod!(ssh, 0o755)
    old_path = System.get_env("PATH")
    System.put_env("PATH", fake_root <> ":" <> old_path)
    System.put_env("FAKE_GH_STATE", fake_root)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      Process.delete(:fake_worktree_reconcile)
      Process.delete(:fake_worktree_ensure)
      Process.delete(:fake_worktree_head)

      for variable <- ~w(
        FAKE_GH_STATE
        FAKE_GH_CHECK_MODE
        FAKE_GH_MERGE_MODE
        FAKE_GH_PR_MODE
        FAKE_GH_REVIEWED_HEAD
        FAKE_GH_MERGE_SHA
        FAKE_SSH_MODE
        FAKE_SSH_OUTPUT
      ) do
        System.delete_env(variable)
      end
    end)

    %{fake_gh_root: fake_root, old_path: old_path}
  end

  test "local readiness waits for natural exit and passes task data without interpolation" do
    worktree = temporary_directory("readiness-worktree")
    marker = Path.join(worktree, "interpolated")
    branch = "$(touch #{marker})"
    task = task_fixture(String.duplicate("a", 40), branch)
    context = %{worktree: worktree, worker_host: nil, readiness_command: "sleep 0.2; printf '%s' \"$SYMPHONY_TASK_BRANCH\""}
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, ^branch} = SystemBoundary.call(:readiness, task, context)
    assert System.monotonic_time(:millisecond) - started_at >= 150
    refute File.exists?(marker)
  end

  test "guarded squash sends the reviewed head as a literal gh argument", %{fake_gh_root: fake_root} do
    {worktree, head} = linear_repository()
    merge_sha = String.duplicate("d", 40)
    task = task_fixture(head)

    System.put_env("FAKE_GH_PR_MODE", "merged")
    System.put_env("FAKE_GH_REVIEWED_HEAD", head)
    System.put_env("FAKE_GH_MERGE_SHA", merge_sha)

    assert {:ok, ^merge_sha} =
             SystemBoundary.call(:guarded_squash, task, %{worktree: worktree, worker_host: nil, reviewed_head: head})

    assert File.read!(Path.join(fake_root, "merge_args")) |> String.split("\n", trim: true) == [
             "pr",
             "merge",
             "42",
             "--squash",
             "--match-head-commit",
             head
           ]
  end

  test "real conflict probing returns exact paths, aborts the merge, and does not interpolate revisions" do
    %{worktree: worktree, feature_head: feature_head, target_head: target_head} = conflicting_repository()
    task = task_fixture(feature_head)
    context = %{worktree: worktree, worker_host: nil, target_head: target_head}

    assert {:conflict, ["conflict.txt"]} = SystemBoundary.call(:probe_conflict, task, context)
    assert git!(worktree, ["rev-parse", "HEAD"]) == feature_head
    assert git!(worktree, ["status", "--porcelain"]) == ""
    assert {_output, status} = System.cmd("git", ["-C", worktree, "rev-parse", "-q", "--verify", "MERGE_HEAD"])
    refute status == 0

    marker = Path.join(worktree, "interpolated-revision")
    malicious_revision = "#{target_head};touch #{marker}"

    assert {:error, {:git_failed, _status, _output}} =
             SystemBoundary.call(:target_ancestor, task, %{context | target_head: malicious_revision})

    refute File.exists?(marker)
  end

  test "real reachability distinguishes an ancestor from an unrelated direction" do
    {worktree, first_head, second_head} = linear_repository_with_two_commits()
    task = task_fixture(second_head)

    assert {:ok, true} =
             SystemBoundary.call(:reachable, task, %{
               worktree: worktree,
               worker_host: nil,
               merge_sha: first_head,
               target_head: second_head
             })

    assert {:ok, false} =
             SystemBoundary.call(:reachable, task, %{
               worktree: worktree,
               worker_host: nil,
               merge_sha: second_head,
               target_head: first_head
             })
  end

  test "failed and pending required checks return to review while gh transport failures stay pending" do
    {worktree, head} = linear_repository()
    provisional = task_fixture(head)
    System.put_env("FAKE_GH_CHECK_MODE", "green")

    assert {:ok, baseline} =
             SystemBoundary.call(:review_snapshot, provisional, %{worktree: worktree, worker_host: nil})

    task = %{
      provisional
      | review_attestation:
          provisional.review_attestation
          |> Map.put("feedback_fingerprint", baseline.feedback_fingerprint)
          |> Map.put("checks_fingerprint", baseline.checks_fingerprint)
    }

    for mode <- ~w(failed pending) do
      System.put_env("FAKE_GH_CHECK_MODE", mode)
      tag = make_ref()

      assert {:ok, :review_required} = run_until_provider_gate(task, worktree, tag)
      assert_receive {^tag, %Commands.InvalidateReviewAttestation{}}
      refute_receive {^tag, :readiness}, 25
    end

    for mode <- ~w(transport auth process) do
      System.put_env("FAKE_GH_CHECK_MODE", mode)
      tag = make_ref()

      assert {:ok, :pending} = run_until_provider_gate(task, worktree, tag)
      refute_receive {^tag, %_{}}, 25
      refute_receive {^tag, :readiness}, 25
    end
  end

  test "worktree setup and source-head failures retain their transient or invariant class" do
    task = task_fixture(String.duplicate("a", 40))
    base = %{worktree: "/tmp/existing", worker_host: nil, worktree_module: FakeWorktree}

    Process.put(:fake_worktree_reconcile, {:ok, %{clean: true}})
    assert {:ok, %{worktree: "/tmp/existing"}} = SystemBoundary.call(:ensure_worktree, task, base)

    Process.put(:fake_worktree_reconcile, {:error, :branch_mismatch})

    assert {:error, {:invariant, {:worktree_reconcile_failed, :branch_mismatch}}} =
             SystemBoundary.call(:ensure_worktree, task, base)

    missing = %{base | worktree: nil}
    Process.put(:fake_worktree_ensure, {:ok, "/tmp/created"})
    assert {:ok, %{worktree: "/tmp/created"}} = SystemBoundary.call(:ensure_worktree, task, missing)

    Process.put(:fake_worktree_ensure, {:error, {:transient, :checkout_busy}})
    assert {:error, {:transient, :checkout_busy}} = SystemBoundary.call(:ensure_worktree, task, missing)

    source_head = String.duplicate("b", 40)
    Process.put(:fake_worktree_head, {:ok, source_head})
    assert {:ok, ^source_head} = SystemBoundary.call(:source_head, task, base)

    Process.put(:fake_worktree_head, {:error, :corrupt_head})
    assert {:error, {:invariant, :corrupt_head}} = SystemBoundary.call(:source_head, task, base)
  end

  test "target fetch and source push classify command status and transport errors" do
    task = task_fixture(String.duplicate("a", 40))

    success = fn _context, args ->
      case args do
        ["rev-parse", _ref] -> {:ok, String.duplicate("b", 40) <> "\n", 0}
        _args -> {:ok, "", 0}
      end
    end

    target_head = String.duplicate("b", 40)
    context = boundary_context("/tmp/fake", %{git_status_runner: success})
    assert {:ok, ^target_head} = SystemBoundary.call(:fetch_target, task, context)
    assert :ok = SystemBoundary.call(:push_head, task, context)

    status_failure = %{context | git_status_runner: fn _context, _args -> {:ok, "network timeout", 7} end}

    assert {:error, {:transient, {:git_failed, _args, 7, "network timeout"}}} =
             SystemBoundary.call(:fetch_target, task, status_failure)

    transport_failure = %{context | git_status_runner: fn _context, _args -> {:error, :port_closed} end}
    assert {:error, :port_closed} = SystemBoundary.call(:fetch_target, task, transport_failure)

    invariant_failure = %{context | git_status_runner: fn _context, _args -> {:ok, "denied", 2} end}

    assert {:error, {:invariant, {:git_failed, _args, 2, "denied"}}} =
             SystemBoundary.call(:push_head, task, invariant_failure)

    stale_failure = %{
      context
      | git_status_runner: fn _context, _args -> {:ok, "rejected (non-fast-forward)", 1} end
    }

    assert {:error, {:stale, {:git_failed, _args, 1, "rejected (non-fast-forward)"}}} =
             SystemBoundary.call(:push_head, task, stale_failure)
  end

  test "ancestor and reachability probes preserve every git exit class" do
    task = task_fixture(String.duplicate("a", 40))
    base = boundary_context("/tmp/fake", %{target_head: String.duplicate("b", 40), merge_sha: String.duplicate("c", 40)})

    for {status, expected} <- [{0, {:ok, true}}, {1, {:ok, false}}, {2, {:error, {:git_failed, 2, "graph"}}}] do
      context = Map.put(base, :git_status_runner, fn _context, _args -> {:ok, "graph", status} end)
      assert ^expected = SystemBoundary.call(:target_ancestor, task, context)
    end

    direct_error = Map.put(base, :git_status_runner, fn _context, _args -> {:error, :graph_transport} end)
    assert {:error, :graph_transport} = SystemBoundary.call(:target_ancestor, task, direct_error)

    for {result, expected} <- [
          {{:ok, "graph", 2}, {:error, {:git_failed, 2, "graph"}}},
          {{:error, :graph_transport}, {:error, :graph_transport}}
        ] do
      context = Map.put(base, :git_status_runner, fn _context, _args -> result end)
      assert ^expected = SystemBoundary.call(:reachable, task, context)
    end
  end

  test "target merge and clean probes expose commit, clean, conflict, and abort failures" do
    task = task_fixture(String.duplicate("a", 40))
    base = boundary_context("/tmp/fake", %{target_head: String.duplicate("b", 40)})
    updated_head = String.duplicate("c", 40)

    commit_runner = fn _context, args ->
      case args do
        ["merge", "--no-edit", _target] -> {:ok, "merged", 0}
        ["rev-parse", "HEAD"] -> {:ok, updated_head <> "\n", 0}
      end
    end

    assert {:ok, ^updated_head} =
             SystemBoundary.call(:merge_target, task, Map.put(base, :git_status_runner, commit_runner))

    clean_runner = fn _context, args ->
      case args do
        ["merge", "--no-commit", "--no-ff", _target] -> {:ok, "clean", 0}
        ["merge", "--abort"] -> {:ok, "", 128}
        ["rev-parse", "-q", "--verify", "MERGE_HEAD"] -> {:ok, "", 1}
      end
    end

    assert {:ok, :clean} =
             SystemBoundary.call(:probe_conflict, task, Map.put(base, :git_status_runner, clean_runner))

    clean_abort_failure = fn _context, args ->
      case args do
        ["merge", "--no-commit", "--no-ff", _target] -> {:ok, "clean", 0}
        ["merge", "--abort"] -> {:error, :clean_abort_transport}
      end
    end

    assert {:error, :clean_abort_transport} =
             SystemBoundary.call(:probe_conflict, task, Map.put(base, :git_status_runner, clean_abort_failure))

    direct_error = Map.put(base, :git_status_runner, fn _context, _args -> {:error, :git_transport} end)
    assert {:error, :git_transport} = SystemBoundary.call(:merge_target, task, direct_error)

    diff_error = fn _context, args ->
      case args do
        ["merge", "--no-commit", "--no-ff", _target] -> {:ok, "merge failed", 1}
        ["merge", "--abort"] -> {:ok, "", 128}
        ["diff" | _rest] -> {:error, :diff_transport}
        ["rev-parse", "-q", "--verify", "MERGE_HEAD"] -> {:ok, "", 1}
      end
    end

    assert {:error, :diff_transport} =
             SystemBoundary.call(:probe_conflict, task, Map.put(base, :git_status_runner, diff_error))

    no_paths = fn _context, args ->
      case args do
        ["merge", "--no-commit", "--no-ff", _target] -> {:ok, "merge failed", 1}
        ["merge", "--abort"] -> {:ok, "", 128}
        ["diff" | _rest] -> {:ok, "", 0}
        ["rev-parse", "-q", "--verify", "MERGE_HEAD"] -> {:ok, "", 1}
      end
    end

    assert {:error, {:git_failed, ["merge" | _rest], "merge failed"}} =
             SystemBoundary.call(:probe_conflict, task, Map.put(base, :git_status_runner, no_paths))

    cleanup_failure = fn _context, args ->
      case args do
        ["merge", "--no-commit", "--no-ff", _target] -> {:ok, "merge failed", 1}
        ["diff" | _rest] -> {:ok, "", 0}
        ["merge", "--abort"] -> {:error, :cleanup_transport}
      end
    end

    assert {:error, :cleanup_transport} =
             SystemBoundary.call(:probe_conflict, task, Map.put(base, :git_status_runner, cleanup_failure))

    for {verification, expected} <- [
          {{:ok, "merge-head", 0}, {:error, {:merge_abort_unverified, 0, "merge-head"}}},
          {{:error, :verification_transport}, {:error, :verification_transport}}
        ] do
      unverified_cleanup = fn _context, args ->
        case args do
          ["merge", "--no-commit", "--no-ff", _target] -> {:ok, "clean", 0}
          ["merge", "--abort"] -> {:ok, "", 128}
          ["rev-parse", "-q", "--verify", "MERGE_HEAD"] -> verification
        end
      end

      assert ^expected =
               SystemBoundary.call(:probe_conflict, task, Map.put(base, :git_status_runner, unverified_cleanup))
    end

    for {abort_result, expected} <- [
          {{:ok, "no merge to abort", 128}, {:error, {:merge_abort_failed, 128, "no merge to abort"}}},
          {{:ok, "cannot abort", 3}, {:error, {:merge_abort_failed, 3, "cannot abort"}}},
          {{:error, :abort_transport}, {:error, :abort_transport}}
        ] do
      runner = fn _context, args ->
        case args do
          ["merge", "--no-commit", "--no-ff", _target] -> {:ok, "conflict", 1}
          ["diff" | _rest] -> {:ok, "conflict.txt\n", 0}
          ["merge", "--abort"] -> abort_result
        end
      end

      assert ^expected =
               SystemBoundary.call(:probe_conflict, task, Map.put(base, :git_status_runner, runner))
    end
  end

  test "local readiness distinguishes command failure, missing bash, and process transport", %{old_path: path} do
    worktree = temporary_directory("readiness-failures")
    task = task_fixture(String.duplicate("a", 40))

    assert {:error, {:readiness_failed, 9, "failed"}} =
             SystemBoundary.call(:readiness, task, %{
               worktree: worktree,
               worker_host: nil,
               readiness_command: "printf failed; exit 9"
             })

    empty_path = temporary_directory("empty-path")

    with_path(empty_path, fn ->
      assert {:error, {:invariant, :bash_not_found}} =
               SystemBoundary.call(:readiness, task, %{
                 worktree: worktree,
                 worker_host: nil,
                 readiness_command: "true"
               })
    end)

    with_path(path, fn ->
      assert {:error, {:readiness_transport_failed, _message}} =
               SystemBoundary.call(:readiness, task, %{
                 worktree: worktree,
                 worker_host: nil,
                 readiness_command: 123
               })
    end)
  end

  test "remote readiness escapes task data and classifies exit and SSH failures", %{
    fake_gh_root: fake_root
  } do
    task = task_fixture(String.duplicate("a", 40), "feature/it's-literal")

    context = %{
      worktree: "/tmp/remote worktree's",
      worker_host: "builder:2222",
      readiness_command: "printf ready"
    }

    System.put_env("FAKE_SSH_MODE", "success")
    System.put_env("FAKE_SSH_OUTPUT", "remote-ready")
    assert {:ok, "remote-ready"} = SystemBoundary.call(:readiness, task, context)

    ssh_args = File.read!(Path.join(fake_root, "ssh_args"))
    assert ssh_args =~ "SYMPHONY_TASK_BRANCH="
    assert ssh_args =~ "feature/it"
    assert ssh_args =~ "bash -lc"

    System.put_env("FAKE_SSH_MODE", "failed")
    System.put_env("FAKE_SSH_OUTPUT", "remote-failed")
    assert {:error, {:readiness_failed, 9, "remote-failed"}} = SystemBoundary.call(:readiness, task, context)

    empty_path = temporary_directory("no-ssh")

    with_path(empty_path, fn ->
      assert {:error, {:transient, :ssh_not_found}} = SystemBoundary.call(:readiness, task, context)
    end)
  end

  test "local and SSH git transports preserve command statuses and executable failures", %{old_path: path} do
    task = task_fixture(String.duplicate("a", 40))
    remote = boundary_context("/tmp/remote", %{worker_host: "builder", target_head: String.duplicate("b", 40)})

    System.put_env("FAKE_SSH_MODE", "success")
    System.put_env("FAKE_SSH_OUTPUT", "remote-head\n")
    assert {:ok, true} = SystemBoundary.call(:target_ancestor, task, remote)
    assert {:ok, "remote-head"} = SystemBoundary.call(:fetch_target, task, remote)

    System.put_env("FAKE_SSH_MODE", "failed")
    System.put_env("FAKE_SSH_OUTPUT", "remote-git-failed")
    assert {:error, {:git_failed, 9, "remote-git-failed"}} = SystemBoundary.call(:target_ancestor, task, remote)

    empty_path = temporary_directory("no-git-or-ssh")

    with_path(empty_path, fn ->
      assert {:error, {:transient, :ssh_not_found}} = SystemBoundary.call(:target_ancestor, task, remote)

      local = %{remote | worker_host: nil}
      assert {:error, {:invariant, :git_not_found}} = SystemBoundary.call(:target_ancestor, task, local)
    end)

    with_path(path, fn ->
      invalid = %{remote | worker_host: nil, worktree: 123, target_head: "HEAD"}
      assert {:error, {:git_transport_failed, _args, _message}} = SystemBoundary.call(:target_ancestor, task, invalid)
    end)

    assert {:error, {:invariant, {:unsupported_merge_operation, :unknown}}} =
             SystemBoundary.call(:unknown, task, remote)
  end

  test "guarded squash distinguishes stale, closed, nonterminal, invalid, and provider failures" do
    {worktree, head} = linear_repository()
    task = task_fixture(head)
    context = %{worktree: worktree, worker_host: nil, reviewed_head: head}
    merge_sha = String.duplicate("d", 40)
    System.put_env("FAKE_GH_REVIEWED_HEAD", head)
    System.put_env("FAKE_GH_MERGE_SHA", merge_sha)

    assert {:error, {:stale, :guarded_head_mismatch}} =
             SystemBoundary.call(:guarded_squash, %{task | github: %{}}, context)

    System.put_env("FAKE_GH_MERGE_MODE", "merged")

    for {mode, expected} <- [
          {"closed", {:error, {:missing_or_closed_pr, "CLOSED"}}},
          {"open", {:error, {:transient, {:merge_not_terminal, "OPEN"}}}},
          {"missing_sha", {:error, {:invariant, :invalid_guarded_merge_result}}}
        ] do
      System.put_env("FAKE_GH_PR_MODE", mode)
      assert ^expected = SystemBoundary.call(:guarded_squash, task, context)
    end

    System.put_env("FAKE_GH_PR_MODE", "invalid")
    assert {:error, {:invariant, _reason}} = SystemBoundary.call(:guarded_squash, task, context)

    for {mode, expected_tag} <- [
          {"conflict", :conflict},
          {"stale", :stale},
          {"transport", :transient},
          {"invariant", :invariant}
        ] do
      System.put_env("FAKE_GH_MERGE_MODE", mode)

      case {expected_tag, SystemBoundary.call(:guarded_squash, task, context)} do
        {:conflict, {:conflict, _reason}} -> :ok
        {tag, {:error, {tag, _reason}}} -> :ok
        {_tag, result} -> flunk("unexpected guarded merge classification: #{inspect(result)}")
      end
    end

    System.put_env("FAKE_GH_MERGE_MODE", "merged")
    System.put_env("FAKE_GH_PR_MODE", "merged")

    assert {:ok, ^merge_sha} =
             SystemBoundary.call(:guarded_squash, task, %{
               worktree: "/unused/remote/worktree",
               worker_host: "builder",
               reviewed_head: head,
               bundle: Config.bundle!()
             })
  end

  defp run_until_provider_gate(task, worktree, tag) do
    recipient = self()

    boundary = fn
      :ensure_worktree, _task, context ->
        {:ok, context}

      operation, boundary_task, context when operation in [:source_head, :review_snapshot] ->
        SystemBoundary.call(operation, boundary_task, context)

      :readiness, _task, _context ->
        send(recipient, {tag, :readiness})
        {:ok, "ready"}

      operation, _task, _context ->
        {:error, {:unexpected_operation, operation}}
    end

    board_executor = fn command, _opts ->
      send(recipient, {tag, command})

      updated =
        case command do
          %Commands.InvalidateReviewAttestation{} ->
            %{task | column_id: "automated_review", review_attestation: nil, revision: task.revision + 1}

          %Commands.BlockTask{} ->
            %{task | column_id: "blocked", review_attestation: nil, revision: task.revision + 1}
        end

      {:ok, %{"task" => Task.to_map(updated)}}
    end

    DeterministicMerge.run(task, Config.bundle!(),
      boundary: boundary,
      board_executor: board_executor,
      location: %{worktree: worktree, worker_host: nil}
    )
  end

  defp boundary_context(worktree, overrides) do
    Map.merge(
      %{
        worktree: worktree,
        worker_host: nil,
        readiness_command: "true",
        bundle: Config.bundle!()
      },
      overrides
    )
  end

  defp with_path(path, callback) do
    previous = System.get_env("PATH")
    System.put_env("PATH", path)

    try do
      callback.()
    after
      System.put_env("PATH", previous)
    end
  end

  defp task_fixture(head, branch \\ "feature/system-boundary") do
    %Task{
      id: Ecto.UUID.generate(),
      identifier: "SYM-BOUNDARY",
      number: System.unique_integer([:positive]),
      project_id: "symphony",
      title: "System boundary",
      type: :feature,
      branch: branch,
      priority: :normal,
      brief: "Exercise real command boundaries",
      acceptance_criteria: [
        %{"id" => Ecto.UUID.generate(), "text" => "Verified", "completed" => true, "evidence" => [%{"result" => "passed"}]}
      ],
      column_id: "merging",
      rank: 1_024,
      revision: 1,
      source: %{"head_sha" => head, "clean" => true},
      github: %{"number" => 42, "head_sha" => head, "state" => "open"},
      review_attestation: %{
        "verdict" => "pass",
        "reviewed_head_sha" => head,
        "feedback_fingerprint" => "feedback",
        "checks_fingerprint" => "checks"
      },
      created_at: "2026-07-16T00:00:00Z",
      updated_at: "2026-07-16T00:00:00Z"
    }
  end

  defp linear_repository do
    worktree = temporary_directory("linear-repository")
    initialize_repository(worktree)
    File.write!(Path.join(worktree, "file.txt"), "first\n")
    commit!(worktree, "first")
    {worktree, git!(worktree, ["rev-parse", "HEAD"])}
  end

  defp linear_repository_with_two_commits do
    {worktree, first_head} = linear_repository()
    File.write!(Path.join(worktree, "file.txt"), "second\n")
    commit!(worktree, "second")
    {worktree, first_head, git!(worktree, ["rev-parse", "HEAD"])}
  end

  defp conflicting_repository do
    worktree = temporary_directory("conflicting-repository")
    initialize_repository(worktree)
    File.write!(Path.join(worktree, "conflict.txt"), "base\n")
    commit!(worktree, "base")
    base_head = git!(worktree, ["rev-parse", "HEAD"])

    git!(worktree, ["checkout", "-b", "target"])
    File.write!(Path.join(worktree, "conflict.txt"), "target\n")
    commit!(worktree, "target")
    target_head = git!(worktree, ["rev-parse", "HEAD"])

    git!(worktree, ["checkout", "-b", "feature", base_head])
    File.write!(Path.join(worktree, "conflict.txt"), "feature\n")
    commit!(worktree, "feature")

    %{worktree: worktree, feature_head: git!(worktree, ["rev-parse", "HEAD"]), target_head: target_head}
  end

  defp initialize_repository(worktree) do
    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", worktree], stderr_to_stdout: true)
    git!(worktree, ["config", "user.name", "Symphony Test"])
    git!(worktree, ["config", "user.email", "symphony@example.test"])
  end

  defp commit!(worktree, message) do
    git!(worktree, ["add", "."])
    git!(worktree, ["commit", "-m", message])
  end

  defp git!(worktree, args) do
    case System.cmd("git", ["-C", worktree | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git command failed status=#{status} args=#{inspect(args)} output=#{output}")
    end
  end

  defp temporary_directory(label) do
    path = Path.join(System.tmp_dir!(), "#{label}-#{Ecto.UUID.generate()}")
    File.mkdir_p!(path)
    path
  end
end
