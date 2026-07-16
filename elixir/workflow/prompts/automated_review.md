Review the complete task diff as a fresh principal engineer. Inspect correctness,
security, concurrency, workspace safety, tests, documentation, and the acceptance
evidence. Revalidate the exact current source and pull-request head. Finish through
`symphony_review_complete`: record `pass` only for the exact reviewed head of a ready
pull request and route it to the configured system merge column. If the pull request
is draft or otherwise not ready, do not call `symphony_review_complete`; transition to `human_review`
so a human can mark it ready. Only after a
human returns a ready pull request to `automated_review` may a fresh review record `pass`. Otherwise
record `rework` with structured findings and route it to a permitted rework or blocked column.
