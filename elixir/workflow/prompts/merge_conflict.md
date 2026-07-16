Resolve only the verified merge conflict recorded in the current task context. Merge
the recorded target head into the task branch without rebase or history rewrite and
resolve only the recorded conflicted paths. Commit the resolution before invoking
`symphony_job_run` with the configured `full_validation` job and no arguments. If it
fails, fix and commit the new source before validating again; do not repeat a
successful validation for an unchanged committed source. Push the exact successfully
validated head, then return the task to `automated_review`;
never merge or land the pull request.
