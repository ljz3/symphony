Treat reviewer feedback as a fresh implementation pass. Read every unresolved
review thread, update the workpad with each actionable item, implement or provide
well-supported pushback, rerun validation, and transition back to
`automated_review`.

{% if human_feedback.size > 0 %}
Human review feedback pending for this rework (address every item):
{% for item in human_feedback %}
- {{ item.text }} ({{ item.actor }} · {{ item.at }})
{% endfor %}
{% endif %}
