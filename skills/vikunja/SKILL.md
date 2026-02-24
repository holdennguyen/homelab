---
name: vikunja
description: Manage Vikunja tasks via API — create, query, update, complete tasks, and send Discord notifications. Enables natural-language task management through Discord and the OpenClaw gateway.
metadata:
  {
    "openclaw":
      {
        "emoji": "📋",
        "requires": { "anyBins": ["curl"] },
      },
  }
---

# Vikunja Integration

Interact with the Vikunja task management API from inside the OpenClaw pod. This skill enables creating, querying, updating, and completing tasks via natural language — from Discord, the Control UI, or any OpenClaw channel.

## Connection details

| Setting | Value |
|---|---|
| Base URL | `http://vikunja.vikunja.svc.cluster.local` |
| API prefix | `/api/v1` |
| Auth header | `Authorization: Bearer $VIKUNJA_API_TOKEN` |
| API docs | `https://vikunja.io/docs/api/` |

The `VIKUNJA_API_TOKEN` env var is injected from Infisical via ESO. All API calls use this token.

## Common variables

Set these at the start of any API interaction:

```bash
VIKUNJA_URL="http://vikunja.vikunja.svc.cluster.local/api/v1"
AUTH="Authorization: Bearer $VIKUNJA_API_TOKEN"
```

## Task operations

### List all projects

```bash
curl -s -H "$AUTH" "$VIKUNJA_URL/projects" | jq '.[] | {id, title, description}'
```

### List tasks in a project

```bash
curl -s -H "$AUTH" "$VIKUNJA_URL/projects/<PROJECT_ID>/tasks" | jq '.[] | {id, title, done, due_date, priority}'
```

### Get tasks due today

```bash
TODAY=$(date -u +%Y-%m-%dT00:00:00Z)
TOMORROW=$(date -u -v+1d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d "+1 day" +%Y-%m-%dT00:00:00Z)
curl -s -H "$AUTH" "$VIKUNJA_URL/tasks/all?filter=due_date>$TODAY&&due_date<$TOMORROW" | jq '.[] | {id, title, due_date, project_id}'
```

### Get overdue tasks

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -s -H "$AUTH" "$VIKUNJA_URL/tasks/all?filter=due_date<$NOW&&done=false" | jq '.[] | {id, title, due_date, project_id}'
```

### Create a task

```bash
curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" \
  "$VIKUNJA_URL/projects/<PROJECT_ID>/tasks" \
  -d '{
    "title": "Task title",
    "description": "Optional description",
    "due_date": "2026-03-01T12:00:00Z",
    "priority": 3
  }' | jq '{id, title, due_date}'
```

Priority levels: 0 (unset), 1 (low), 2 (medium), 3 (high), 4 (urgent), 5 (do now).

### Complete a task

```bash
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$VIKUNJA_URL/tasks/<TASK_ID>" \
  -d '{"done": true}' | jq '{id, title, done}'
```

### Update a task

```bash
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$VIKUNJA_URL/tasks/<TASK_ID>" \
  -d '{
    "title": "Updated title",
    "description": "Updated description",
    "due_date": "2026-03-15T12:00:00Z",
    "priority": 4
  }' | jq '{id, title, due_date, priority}'
```

### Delete a task

```bash
curl -s -X DELETE -H "$AUTH" "$VIKUNJA_URL/tasks/<TASK_ID>"
```

### Search tasks

```bash
curl -s -H "$AUTH" "$VIKUNJA_URL/tasks/all?s=search+term" | jq '.[] | {id, title, done, project_id}'
```

## Label operations

### List all labels

```bash
curl -s -H "$AUTH" "$VIKUNJA_URL/labels" | jq '.[] | {id, title, hex_color}'
```

### Add label to a task

```bash
curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" \
  "$VIKUNJA_URL/tasks/<TASK_ID>/labels" \
  -d '{"label_id": <LABEL_ID>}'
```

## Discord notification patterns

The `DISCORD_WEBHOOK_VIKUNJA` env var contains a Discord webhook URL for posting task notifications.

### Send a task notification to Discord

```bash
curl -s -X POST -H "Content-Type: application/json" \
  "$DISCORD_WEBHOOK_VIKUNJA" \
  -d '{
    "embeds": [{
      "title": "Task Created",
      "description": "**Task title here**\nDue: 2026-03-01\nPriority: High",
      "color": 5814783,
      "footer": {"text": "Vikunja • Project Name"}
    }]
  }'
```

### Color codes for embed severity

| Priority | Color (decimal) | Hex |
|---|---|---|
| Do Now (5) | 15158332 | `#E74C3C` |
| Urgent (4) | 15105570 | `#E67E22` |
| High (3) | 16776960 | `#FFFF00` |
| Medium (2) | 5814783 | `#58B9FF` |
| Low (1) | 3066993 | `#2ECC71` |
| Unset (0) | 9807270 | `#95A5A6` |

### Notify on task completion

```bash
TASK=$(curl -s -H "$AUTH" "$VIKUNJA_URL/tasks/<TASK_ID>" | jq -r '.title')
curl -s -X POST -H "Content-Type: application/json" \
  "$DISCORD_WEBHOOK_VIKUNJA" \
  -d "{
    \"embeds\": [{
      \"title\": \"✅ Task Completed\",
      \"description\": \"**$TASK**\",
      \"color\": 3066993,
      \"footer\": {\"text\": \"Vikunja\"}
    }]
  }"
```

### Send daily summary to Discord

```bash
TODAY=$(date -u +%Y-%m-%dT00:00:00Z)
TOMORROW=$(date -u -v+1d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d "+1 day" +%Y-%m-%dT00:00:00Z)
TASKS=$(curl -s -H "$AUTH" "$VIKUNJA_URL/tasks/all?filter=due_date>$TODAY&&due_date<$TOMORROW&&done=false" | jq -r '.[] | "• \(.title) (priority: \(.priority))"')
if [ -n "$TASKS" ]; then
  curl -s -X POST -H "Content-Type: application/json" \
    "$DISCORD_WEBHOOK_VIKUNJA" \
    -d "{
      \"embeds\": [{
        \"title\": \"📅 Tasks Due Today\",
        \"description\": \"$TASKS\",
        \"color\": 5814783,
        \"footer\": {\"text\": \"Vikunja Daily Summary\"}
      }]
    }"
fi
```

## Discord command patterns

When a user asks about tasks in Discord (or any channel), interpret their intent and execute the appropriate API call. Common patterns:

| User says | Action |
|---|---|
| "add a todo: buy groceries" | Create task in default project |
| "what's due today?" | List tasks due today |
| "show my tasks" / "todo list" | List all incomplete tasks |
| "complete task 42" / "done with task 42" | Mark task as done |
| "what's overdue?" | List overdue tasks |
| "search tasks for deployment" | Search tasks by keyword |
| "add todo: fix CI due Friday priority high" | Create task with due date and priority |

### Parsing natural language due dates

Convert relative dates before API calls:

| Input | Interpretation |
|---|---|
| "today" | Current date, end of day |
| "tomorrow" | Next day, end of day |
| "Friday" / "next Friday" | Next occurrence of that weekday |
| "next week" | Monday of next week |
| "in 3 days" | Current date + 3 days |

Use `date` commands to compute the ISO 8601 timestamp for the `due_date` field.

### Default project

If the user doesn't specify a project, list projects first and use the first available one. Cache the project ID during the session to avoid repeated lookups.

## Webhook setup (Vikunja → Discord)

Vikunja supports project-level webhooks for automated notifications. Set them up via the API:

### Create a webhook for task events

```bash
curl -s -X PUT -H "$AUTH" -H "Content-Type: application/json" \
  "$VIKUNJA_URL/projects/<PROJECT_ID>/webhooks" \
  -d "{
    \"target_url\": \"$DISCORD_WEBHOOK_VIKUNJA\",
    \"events\": [\"task.created\", \"task.updated\", \"task.deleted\", \"task.assignee.created\"],
    \"secret\": \"\"
  }" | jq '{id, target_url, events}'
```

### List webhooks for a project

```bash
curl -s -H "$AUTH" "$VIKUNJA_URL/projects/<PROJECT_ID>/webhooks" | jq '.[] | {id, target_url, events}'
```

### Delete a webhook

```bash
curl -s -X DELETE -H "$AUTH" "$VIKUNJA_URL/projects/<PROJECT_ID>/webhooks/<WEBHOOK_ID>"
```

Note: Vikunja webhook payloads use Vikunja's own JSON format, not Discord's embed format. For formatted Discord messages, use the agent-mediated notification patterns above instead of direct Vikunja-to-Discord webhooks.

## Error handling

| HTTP Status | Meaning | Action |
|---|---|---|
| 200 | Success | Parse response |
| 400 | Bad request | Check request body format |
| 401 | Unauthorized | Verify `VIKUNJA_API_TOKEN` is set and valid |
| 403 | Forbidden | Token lacks permission for this operation |
| 404 | Not found | Verify project/task ID exists |
| 500 | Server error | Check Vikunja pod logs: `kubectl logs -n vikunja deploy/vikunja --tail=50` |

If the API returns 401, inform the user that the Vikunja API token may need to be regenerated and updated in Infisical.

## Health check

Verify Vikunja is reachable from the OpenClaw pod:

```bash
curl -s http://vikunja.vikunja.svc.cluster.local/api/v1/info | jq '{version, frontend_url}'
```

This endpoint does not require authentication and confirms both the API and network policy are working.
