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

Fetch tasks from each project and filter by due date (the `/tasks/all` endpoint is unavailable in Vikunja v1.1.0):

```bash
PROJECTS=$(curl -s -H "$AUTH" "$VIKUNJA_URL/projects" | jq -r '.[].id')
TODAY=$(date -u +%Y-%m-%d)
for PID in $PROJECTS; do
  curl -s -H "$AUTH" "$VIKUNJA_URL/projects/$PID/tasks" | jq --arg today "$TODAY" '.[] | select(.done == false and (.due_date[:10] == $today)) | {id, title, due_date, priority, project_id}'
done
```

### Get overdue tasks

```bash
PROJECTS=$(curl -s -H "$AUTH" "$VIKUNJA_URL/projects" | jq -r '.[].id')
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for PID in $PROJECTS; do
  curl -s -H "$AUTH" "$VIKUNJA_URL/projects/$PID/tasks" | jq --arg now "$NOW" '.[] | select(.done == false and .due_date > "0001" and .due_date < $now) | {id, title, due_date, priority, project_id}'
done
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

Search across all projects by iterating:

```bash
TERM="search term"
PROJECTS=$(curl -s -H "$AUTH" "$VIKUNJA_URL/projects" | jq -r '.[].id')
for PID in $PROJECTS; do
  curl -s -H "$AUTH" "$VIKUNJA_URL/projects/$PID/tasks" | jq --arg term "$TERM" '[.[] | select(.title | ascii_downcase | contains($term | ascii_downcase))] | .[] | {id, title, done, project_id}'
done
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
TODAY=$(date -u +%Y-%m-%d)
PROJECTS=$(curl -s -H "$AUTH" "$VIKUNJA_URL/projects" | jq -r '.[].id')
TASKS=""
for PID in $PROJECTS; do
  PROJ_TASKS=$(curl -s -H "$AUTH" "$VIKUNJA_URL/projects/$PID/tasks" | jq -r --arg today "$TODAY" '.[] | select(.done == false and (.due_date[:10] == $today)) | "• \(.title) (priority: \(.priority))"')
  if [ -n "$PROJ_TASKS" ]; then
    TASKS="${TASKS}${PROJ_TASKS}\n"
  fi
done
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

## Daily routine project

Project **ID 2** is the daily routine project. It contains ~21 recurring tasks that form Holden's personalized health routine. Always use project 2 when creating, updating, or querying routine-related tasks.

### Time blocks

The routine is structured in blocks. When the user wants to add something, the agent must know which block it falls into and whether there's a gap:

| Block | Time range | Purpose |
|---|---|---|
| Morning | 5:30 – 7:30 AM | Wake, stretch, exercise, breakfast, reading |
| Work | 8:00 AM – 5:00 PM | SRE work + health breaks at 10:00 AM, 12:00 PM, 3:00 PM |
| Fitness | 5:30 – 6:30 PM | Strength (M/W/F) or cardio (Tu/Th) |
| Dinner | 6:30 – 7:30 PM | Meal (finish by 7:30 PM) |
| Creative | 7:30 – 8:30 PM | Piano (M/W/F) or guitar (Tu/Th), then singing |
| Wind-down | 8:30 – 9:30 PM | Reading, sleep prep, lights out |

### Fetch today's schedule

```bash
VIKUNJA_URL="http://vikunja.vikunja.svc.cluster.local/api/v1"
AUTH="Authorization: Bearer $VIKUNJA_API_TOKEN"
TODAY=$(TZ=Asia/Ho_Chi_Minh date +%Y-%m-%d)
curl -s -H "$AUTH" "$VIKUNJA_URL/projects/2/tasks?sort_by=due_date&order_by=asc" \
  | jq --arg today "$TODAY" '[.[] | select(.done == false and (.due_date[:10] == $today))] | sort_by(.due_date) | .[] | {id, title, due_date, priority, repeat_after}'
```

### Find available gaps

After fetching the schedule, identify gaps between tasks. Available slots for new activities:

| Preferred slot | When | Good for |
|---|---|---|
| 7:30 – 8:00 AM | After breakfast, before work | Quick personal tasks, journaling |
| 12:30 – 1:00 PM | After post-lunch walk | Short errands, calls |
| 5:00 – 5:30 PM | After work, before workout | Transition tasks, quick errands |
| 8:15 – 8:30 PM | Between singing and reading | Flexible buffer |

**Never suggest placing tasks during**: sleep prep (9:00–9:30 PM), lights-out (after 9:30 PM), or within the workout block (5:30–6:30 PM) unless it replaces the workout.

## Schedule-aware task management

When the user asks to add something to their schedule via Discord, follow this workflow:

### Step 1: Understand the request

Parse what the user wants. Examples:
- "add meditation to my routine" → new recurring task
- "I want to learn Japanese" → needs time slot suggestion
- "move guitar to Saturday" → reschedule existing task
- "remind me to call the dentist tomorrow at 2 PM" → one-time task

### Step 2: Review current schedule

Always fetch the current day's tasks before suggesting placement. Show the user what's already scheduled around the proposed time.

### Step 3: Suggest optimal placement

Based on the request type:

| Request | Suggestion logic |
|---|---|
| New daily habit (5–15 min) | Find the nearest gap in the appropriate block. Short habits go in morning or wind-down. |
| New skill/hobby (30+ min) | Suggest the creative block (7:30–8:30 PM) or weekend afternoons. Check for conflicts with piano/guitar rotation. |
| One-time errand/appointment | Place during work breaks (10 AM, 12:30 PM, 3 PM) or the 5:00–5:30 PM buffer. |
| Workout change | Replace the existing fitness block entry for that day. Warn about rest day impact. |
| Social/event | Evening slots may conflict with creative time — offer trade-offs ("Skip guitar tonight to make room?"). |

### Step 4: Confirm and create

Present the suggestion to the user with context:
```
"You currently have piano at 7:30 PM and singing at 8:00 PM.
I can slot meditation in at 8:15 PM (15 min) — right between singing and your evening reading at 8:30 PM.
Want me to add it?"
```

Only create/update the task after user confirmation.

### Step 5: Notify on change

After creating or updating a task, post a confirmation embed to Discord:

```bash
curl -s -X POST -H "Content-Type: application/json" "$DISCORD_WEBHOOK_VIKUNJA" \
  -d '{
    "embeds": [{
      "title": "📅 Schedule Updated",
      "description": "**Meditation (15 min)** added at 8:15 PM daily\nSlotted between singing and evening reading",
      "color": 3066993,
      "footer": {"text": "Vikunja • Daily Routine"}
    }]
  }'
```

### Handling conflicts

If the requested time overlaps with an existing task:

1. **Show the conflict**: "That slot is taken by [task] at [time]"
2. **Offer alternatives**: Suggest 2–3 nearby gaps
3. **Offer to swap**: "I can move [existing task] to [new time] to make room — want me to?"
4. **Respect health priorities**: Never suggest removing nutrition, hydration, eye breaks, or sleep prep tasks. These are non-negotiable.

### Rescheduling tasks

To move a task to a different time:

```bash
# Update the due_date to the new time
curl -s -X POST -H "$AUTH" -H "Content-Type: application/json" \
  "$VIKUNJA_URL/tasks/<TASK_ID>" \
  -d '{"due_date": "2026-02-26T20:15:00Z"}'
```

When rescheduling recurring tasks, note that changing `due_date` affects only the current occurrence — the `repeat_after` interval stays the same.

## Discord command patterns

When a user asks about tasks in Discord (or any channel), interpret their intent and execute the appropriate API call. Common patterns:

| User says | Action |
|---|---|
| "add a todo: buy groceries" | Create task in default project |
| "what's due today?" | List tasks due today |
| "show my tasks" / "todo list" | List all incomplete tasks |
| "show my schedule" / "what's my day look like?" | Fetch today's routine from project 2, display in time order |
| "complete task 42" / "done with task 42" | Mark task as done |
| "what's overdue?" | List overdue tasks |
| "search tasks for deployment" | Search tasks by keyword |
| "add todo: fix CI due Friday priority high" | Create task with due date and priority |
| "add meditation to my routine" | Review schedule → suggest slot → confirm → create recurring task in project 2 |
| "move piano to 8 PM" | Find the piano task → reschedule → confirm |
| "skip workout today" | Mark today's workout as done (skip) without deleting the recurring task |
| "I have a dentist appointment Thursday at 2 PM" | Create one-time task in project 2 at the requested time |
| "what can I fit in after work?" | Show 5:00–5:30 PM gap and any other evening availability |
| "change my morning walk to 6:30" | Update the recurring walk task's due_date |

### Parsing natural language due dates

Convert relative dates before API calls:

| Input | Interpretation |
|---|---|
| "today" | Current date, end of day |
| "tomorrow" | Next day, end of day |
| "Friday" / "next Friday" | Next occurrence of that weekday |
| "next week" | Monday of next week |
| "in 3 days" | Current date + 3 days |
| "after work" | 5:00 PM on the relevant day |
| "before bed" | 8:30 PM (before sleep prep at 9:00 PM) |
| "morning" | 7:30 AM (post-breakfast gap) |
| "lunch break" | 12:30 PM |

Use `date` commands to compute the ISO 8601 timestamp for the `due_date` field.

### Default project

When the user is in the `#daily-briefing` channel, default to **project 2** (Daily Routine) for all task operations. In other channels, list projects and use the first available one unless specified.

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
