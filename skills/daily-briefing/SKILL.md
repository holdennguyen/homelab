---
name: daily-briefing
description: Compose a personalized daily briefing with real-time weather, Vikunja tasks, cluster health, and contextual lifestyle advice. Delivered to Discord as a morning digest.
metadata:
  {
    "openclaw":
      {
        "emoji": "🌅",
        "requires": { "anyBins": ["curl"] },
      },
  }
---

# Daily Briefing

Compose and deliver a rich, personalized daily briefing to Discord. This is NOT a boring task list — it's an AI-powered morning digest that combines real-time data with contextual advice.

## Owner profile

Use this profile to personalize every briefing. Never mention the raw data — weave it naturally into advice.

| Attribute | Value |
|---|---|
| Name | Holden |
| Age / Gender | 30s, male |
| Height / Weight | 182 cm / 56 kg (BMI ~16.9 — underweight) |
| Occupation | Site Reliability Engineer, 8 AM – 5 PM weekdays |
| Health goals | Gain healthy weight (target ~70 kg), improve sleep, reduce headaches |
| Known issues | Insomnia, frequent headaches (likely from screen time + poor sleep + dehydration) |
| Nutrition target | 2,500–3,000 kcal/day, 120 g+ protein, 2.5–3 L water |
| Exercise plan | Strength training Mon/Wed/Fri, cardio Tue/Thu, rest weekends |
| Creative interests | Reading (books), singing, piano (Mon/Wed/Fri), guitar (Tue/Thu) |
| Location | Ho Chi Minh City, Vietnam (UTC+7) |

### How to use the profile

- **Weather + fitness**: If it's hot (>32 °C), remind to exercise early or indoors and drink extra water. If rainy, suggest indoor workout alternatives.
- **Nutrition nudges**: Tie weather to appetite ("Hot days can suppress appetite — don't skip your mid-morning snack, you need those 250 extra calories").
- **Headache prevention**: On high-UV or hot days, emphasize hydration and eye breaks. After poor-sleep nights, suggest lighter exercise.
- **Insomnia coaching**: Reinforce the 9:30 PM lights-out target. If it's a weekend, still discourage sleeping in past 6:30 AM (consistency matters more than catch-up sleep).
- **Creative motivation**: Reference the evening music/reading block with enthusiasm, not as a chore. ("Tonight is a piano night — what piece are you working on?")
- **Weight gain framing**: Always positive. Never say "you're underweight." Instead: "Keep fueling up — every meal counts toward your strength goals."
- **Day-of-week awareness**: Know which activities are scheduled (M/W/F = strength + piano, Tu/Th = cardio + guitar, weekends = rest + meal prep).

## Philosophy

Traditional reminder apps dump a static checklist. This briefing is different:

- **Context-aware**: Weather conditions influence activity suggestions (e.g., "It's 34°C — hydrate extra during your workout" or "Rain expected — move your run indoors")
- **Time-aware**: Greeting and tone adapt to the time of day
- **Health-aware**: Advice is tailored to the owner's specific goals — weight gain, sleep improvement, headache prevention
- **Synthesized**: The agent reads multiple data sources, then composes a single coherent narrative — not separate blocks pasted together
- **Actionable**: Every piece of information connects to a suggestion or next step

## Data sources

Gather these in parallel before composing the briefing:

### 1. Weather (Open-Meteo — no API key)

```bash
curl -s "https://api.open-meteo.com/v1/forecast?latitude=10.82&longitude=106.63&current_weather=true&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max,weathercode,uv_index_max,sunrise,sunset&hourly=temperature_2m,precipitation_probability,weathercode&timezone=Asia/Ho_Chi_Minh&forecast_days=1"
```

Location: Ho Chi Minh City (lat 10.82, lon 106.63, tz Asia/Ho_Chi_Minh).

#### WMO weather code reference

| Code | Meaning |
|---|---|
| 0 | Clear sky |
| 1-3 | Partly cloudy / Overcast |
| 45, 48 | Fog |
| 51-55 | Drizzle |
| 61-65 | Rain |
| 66-67 | Freezing rain |
| 71-75 | Snowfall |
| 80-82 | Rain showers |
| 95, 96, 99 | Thunderstorm |

### 2. Tasks due today (Vikunja)

The `/tasks/all` endpoint is unavailable in Vikunja v1.1.0. Fetch per-project instead:

```bash
VIKUNJA_URL="http://vikunja.vikunja.svc.cluster.local/api/v1"
AUTH="Authorization: Bearer $VIKUNJA_API_TOKEN"

# Get all project IDs
PROJECTS=$(curl -s -H "$AUTH" "$VIKUNJA_URL/projects" | jq -r '.[].id')

# For each project, get incomplete tasks
for PID in $PROJECTS; do
  curl -s -H "$AUTH" "$VIKUNJA_URL/projects/$PID/tasks" | jq '.[] | select(.done == false) | {id, title, due_date, priority, project_id}'
done
```

To find overdue tasks, filter results where `due_date` is before now and after `"0001"` (unset dates use year 0001).

### 3. Cluster health (quick pulse)

```bash
kubectl get pods -A --no-headers | awk '{print $4}' | sort | uniq -c | sort -rn
kubectl get applications -n argocd --no-headers -o custom-columns='NAME:.metadata.name,HEALTH:.status.health.status,SYNC:.status.sync.status' | grep -v "Healthy.*Synced" || echo "all-healthy"
```

### 4. Date context

```bash
date -u '+%A, %B %d, %Y'
TZ=Asia/Ho_Chi_Minh date '+%H:%M %Z'
```

## Composing the briefing

After gathering all data, compose a SINGLE cohesive Discord message. Do NOT just paste raw data — synthesize it.

### Structure

Use the Discord webhook (`$DISCORD_WEBHOOK_VIKUNJA`) with embeds:

```
Embed 1: Daily Briefing header
- Title: "Good morning, Holden ☀️" (or appropriate greeting for time of day)
- Description: A 2-3 sentence opening that weaves together weather + day context + what kind of day it is
  Example: "Happy Tuesday in Saigon — 32°C, overcast, no rain expected.
  It's a cardio + guitar day. You have 3 tasks due and 0 overdue — nice streak!"

Embed 2: Weather snapshot
- Inline fields: Current temp, High/Low, Rain chance, UV Index, Sunrise/Sunset

Embed 3: Today's schedule
- Morning block: wake-up, stretch, walk/jog, breakfast, reading
- Work health breaks: snack times, eye breaks, hydration reminders
- Evening block: workout type for today, dinner, which instrument tonight, reading, sleep prep
- Use ✅ for upcoming, 🔴 for overdue
- Emphasize which creative activity is on the schedule today (piano vs guitar)

Embed 4: Health & wellness nudge
- One personalized tip based on weather + day-of-week + health profile
- Examples:
  - "Strength day + 34°C = hydrate aggressively. Add a protein shake post-workout to hit your calorie target."
  - "Rainy Tuesday — swap your morning jog for 20 min jump rope indoors. Still a cardio day!"
  - "It's Friday — you've got piano tonight. Close the laptop by 7:30 and let the music decompress your week."
- Keep this warm and encouraging, never clinical

Embed 5 (optional): Cluster health
- ONLY if something is degraded
- Omit entirely when all systems healthy
```

### Contextual advice patterns

#### Weather-driven

| Condition | Advice |
|---|---|
| Temp > 35°C | "Extreme heat — push your workout earlier and add an extra 500 ml water today" |
| Temp > 32°C | "Hot day — exercise early before it heats up. Heat can suppress appetite, so don't skip meals" |
| Rain > 60% chance | "Rain likely — swap the morning walk for indoor stretching or a longer yoga session" |
| UV > 8 | "Very high UV — sunscreen is non-negotiable if you go outside. Also protects against headaches from sun exposure" |
| Thunderstorm codes (95-99) | "Thunderstorms expected — perfect evening for indoor piano/guitar practice" |

#### Health-driven

| Condition | Advice |
|---|---|
| Monday / Wednesday / Friday | "Strength day: focus on compound lifts. Eat a big post-workout meal within 1 hour" |
| Tuesday / Thursday | "Cardio day: 30 min moderate pace. Great for appetite and sleep quality. Guitar night!" |
| Saturday | "Rest day + meal prep day — batch cook protein-rich meals for the week" |
| Sunday | "Rest + weekly review: how was sleep this week? Weight trend? Headache count?" |
| Any day, hot weather | "Dehydration triggers headaches — keep a water bottle at your desk and aim for 3L today" |
| Evening block reminder | Frame creatively: "Piano night — what are you working on?" or "Guitar evening — time to unwind with some chords" |

#### Task-driven

| Condition | Advice |
|---|---|
| 0 overdue, 0 today tasks | "Clean slate today! Good time to plan ahead or tackle a personal project" |
| Overdue tasks > 0 | "You have N overdue tasks — clearing those first will feel great and reduce mental load" |
| High priority task due | "Heads up: [task name] is high priority and due today" |
| Nutrition tasks not done | Gently nudge: "Don't skip snacks — consistent calories are key to hitting your 2,500 kcal target" |

#### Cluster-driven

| Condition | Advice |
|---|---|
| Cluster degraded | "⚠ Cluster alert: [service] is [status] — may need attention" |
| All systems healthy | Omit cluster section entirely (no news is good news) |

### Color scheme

| Section | Color (decimal) | Meaning |
|---|---|---|
| Header | 5814783 | Blue — informational |
| Weather | 16760576 | Orange — warmth |
| Schedule (all good) | 3066993 | Green |
| Schedule (overdue) | 15158332 | Red — attention |
| Health nudge | 10070709 | Light purple — advisory |
| Cluster alert | 15158332 | Red — attention |

### Sending the message

Post to the `#daily-briefing` channel via its dedicated webhook:

```bash
curl -s -X POST -H "Content-Type: application/json" "$DISCORD_WEBHOOK_VIKUNJA" \
  -d '<composed JSON with embeds array>'
```

Keep total embed content under 6000 characters (Discord limit).

For cluster alerts, use the `#alerts` channel webhook instead:

```bash
curl -s -X POST -H "Content-Type: application/json" "$DISCORD_WEBHOOK_ALERTS" \
  -d '<alert embed JSON>'
```

## Routine schedule reference

The agent should be aware of the full weekly structure when composing briefings:

### Weekday schedule (Mon–Fri)

| Time | Activity | Notes |
|---|---|---|
| 5:30 AM | Wake + hydrate (500 ml warm water) | Non-negotiable. Helps headaches. |
| 5:45 AM | Morning stretch + breathing (15 min) | Yoga + box breathing. Neck/shoulders focus. |
| 6:00 AM | Morning walk or jog (30 min) | Zone 2 cardio. Sunlight for circadian rhythm. |
| 6:30 AM | **Daily briefing arrives** | |
| 7:00 AM | Breakfast (600–700 kcal, 30g+ protein) | Eggs, toast, avocado, banana smoothie |
| 7:30 AM | Morning reading (20 min) | Physical book before screens |
| 8:00 AM | **Work starts** | |
| 10:00 AM | Snack (250 cal) + eye break + neck stretch | Trail mix, yogurt, protein bar |
| 12:00 PM | Lunch (700–800 kcal) | Away from desk |
| 12:30 PM | Post-lunch walk (15 min) | |
| 3:00 PM | Snack (250–300 cal) + eye break + stretch | Nuts, smoothie, cheese + crackers |
| 5:00 PM | **Work ends** | |
| 5:30 PM | Workout: Strength (M/W/F) or Cardio (Tu/Th) | Compound lifts or 30 min moderate cardio |
| 6:30 PM | Dinner (700–800 kcal) | Finish by 7:30 PM |
| 7:30 PM | Music: Piano (M/W/F) or Guitar (Tu/Th) — 30 min | |
| 8:00 PM | Singing practice (15 min) | Breathing exercise + stress relief |
| 8:30 PM | Evening reading (20–30 min) | Physical book, warm dim light |
| 9:00 PM | Sleep prep: screens off, herbal tea, journal | 3 good things from today |
| 9:30 PM | Lights out | 8 hours target → 5:30 AM wake |

### Weekend schedule (Sat–Sun)

| Time | Activity |
|---|---|
| 6:30 AM | Wake (30 min later, but consistent) |
| Morning | Stretch + walk (same as weekday) |
| 10:00 AM | Meal prep (Saturday) / Weekly review (Sunday) |
| Afternoon | Free time — longer music sessions, reading, outdoor activities |
| Evening | Same wind-down routine as weekdays (9:00 PM prep, 9:30 PM lights out) |

### Daily nutrition targets

| Meal | Calories | Protein |
|---|---|---|
| Breakfast | 600–700 | 30 g+ |
| Mid-morning snack | 250 | 10 g |
| Lunch | 700–800 | 35 g+ |
| Afternoon snack | 250–300 | 10 g |
| Dinner | 700–800 | 35 g+ |
| **Daily total** | **2,500–3,000** | **120 g+** |

Water target: 2.5–3 L / day. More on hot days (>32 °C).

## Cron schedule

The briefing should run daily at **6:30 AM ICT (23:30 UTC previous day)**.

Cron expression: `30 23 * * *` (UTC) which is 6:30 AM ICT (UTC+7).

## Error handling

If any data source fails, compose the briefing with whatever data IS available. Never skip the entire briefing because one API timed out. Mention the gap: "Weather data unavailable — check wttr.in manually."
