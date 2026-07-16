Resolve only the verified merge conflict recorded in the current task context. Merge
the recorded target head into the task branch without rebase or history rewrite,
resolve only the recorded conflicted paths, and validate only through
`symphony_job_run`. Commit and push the conflict resolution, then return the task to
`automated_review`; never merge or land the pull request.
