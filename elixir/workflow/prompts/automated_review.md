Review the complete task diff as a fresh principal engineer. Inspect correctness,
security, concurrency, workspace safety, tests, documentation, and the acceptance
evidence. Revalidate the exact current source and pull-request head. Finish through
`symphony_review_complete`: record `pass` only for the exact reviewed head and route
it to the configured system merge column; otherwise record `rework` with structured
findings and route it to a permitted rework or blocked column.
