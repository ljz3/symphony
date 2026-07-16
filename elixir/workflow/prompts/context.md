Task {{ task.identifier }}: {{ task.title }}

Type: {{ task.type }}
Priority: {{ task.priority }}
Branch: {{ task.branch }}
Stage: {{ stage.id }}
Run: {{ run.id }}

Brief:
{{ task.brief }}

Acceptance criteria:
{% for criterion in criteria %}
- [{% if criterion.completed %}x{% else %} {% endif %}] {{ criterion.text }}
{% endfor %}

{% if dependencies %}
Dependencies:
{% for dependency in dependencies %}
- {{ dependency.identifier }} — {{ dependency.title }} ({{ dependency.column_id }})
{% endfor %}
{% endif %}

{% if latest_workpad %}
Latest meaningful workpad (run {{ latest_workpad.run_id }}, invocation {{ latest_workpad.invocation }}):
{{ latest_workpad.content }}
{% endif %}

Allowed transitions:
{% for transition in allowed_transitions %}
- {{ transition.id }} — {{ transition.name }}
{% endfor %}
