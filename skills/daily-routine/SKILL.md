---
name: daily-routine
description: Proactive daily schedule coach for bulk & mobility program — meals, training, hydration, and wellness reminders via Discord.
metadata:
  openclaw:
    emoji: "💪"
    requires: { anyBins: ["curl"] }
---

# Daily Routine

A proactive health and schedule assistant that sends contextual reminders throughout the day via Discord webhooks. Built around a lean bulk & mobility program for a 181 cm / 56 kg individual targeting ~72 kg (BMI 22).

## Learner Profile

| Attribute | Value |
|---|---|
| Height / Weight | 181 cm / 56 kg (BMI 17.1) |
| Target weight | ~72 kg (BMI 22) |
| Occupation | Senior SRE (08:00–17:00 shift) |
| Training days | Mon, Tue, Thu, Fri (home workout) |
| Rest days | Wed, Sat, Sun |

## Nutrition Targets

| Metric | Value |
|---|---|
| TDEE | ~2,150 kcal |
| Daily surplus target | 2,650–2,750 kcal |
| Protein | ~165g (25%) |
| Carbs | ~330g (50%) |
| Fats | ~75g (25%) |
| Hydration | Minimum 2.5L water/day |

## Daily Schedule (ICT — Asia/Ho_Chi_Minh)

| Time | Event | Details |
|---|---|---|
| 07:00 | Breakfast | 2 eggs + 2 slices sourdough + 1 banana + milk |
| 10:00 | Snack 1 | Handful of almonds/cashews + yogurt |
| 12:00 | Lunch | 2 bowls rice + 150g protein (chicken/beef) + greens |
| 15:30 | Snack 2 | Pre-workout fuel: sweet potato or protein bar (training days only) |
| 18:00 | Training | 45–60 min home workout (Mon/Tue/Thu/Fri only) |
| 19:30 | Dinner | 1.5 bowls rice + 150g fish/pork + salad |
| 22:00 | Late snack | Warm milk or an apple |

## Vietnamese Meal Prep Options

Rotate these work-friendly meals:

- **Honey-Garlic Chicken Breast** — seared with fish sauce; honey provides clean mass-gain calories
- **Beef Stir-fry with Broccoli** — high protein + iron + recovery nutrients
- **Stuffed Tofu in Tomato Sauce** — excellent mix of plant and animal protein
- **Braised Pork with Eggs (Thịt Kho Trứng)** — traditional, calorie-dense, microwave-friendly
- **Snacks** — greek yogurt with nuts, boiled sweet potatoes, or Bánh Bao (meat & egg bun)

## Home Workout Program

Training days: Mon, Tue, Thu, Fri

### Strength Block (3–4 sets, 60–90s rest)

1. **Push-ups:** 10–15 reps (chest, shoulders, triceps)
2. **Air Squats:** 20 reps (quads, glutes)
3. **Plank:** Hold 45–60s (core stability)
4. **Lunges:** 12 reps per side (balance & unilateral strength)
5. **Superman:** 15 reps (lower back — essential for desk workers)

### SRE Posture & Mobility (10 min post-workout)

- **Cobra Stretch** — relieve abdominal tension
- **Child's Pose** — decompress the spine after sitting
- **Pigeon Pose** — open tight hips from long desk hours

## Specialized Advice

- **On-Call Adjustments:** After a high-stress on-call night, increase carb intake the next day to prevent cortisol-induced weight loss.
- **Progress Tracking:** Track weight like a system metric. If flat for 2 weeks, increase calories by 10%.
- **Hydration:** Minimum 2.5L water/day for muscle protein synthesis.

## Discord Webhook Format

Post reminders as rich embeds:

```bash
curl -s -X POST -H "Content-Type: application/json" "$DISCORD_WEBHOOK_DAILY" \
  -d '{
    "embeds": [{
      "title": "💪 [Reminder Title]",
      "description": "[Context-appropriate message in Vietnamese]",
      "color": 5763719,
      "footer": {"text": "Daily Routine Coach • Bulk & Mobility Program"}
    }]
  }'
```

Color scheme:
- Meals: `5763719` (green)
- Training: `15105570` (orange)
- Wind-down: `5793266` (teal)
- Morning briefing: `3447003` (blue)

## Cron Schedule Overview

| Time (ICT) | Job | Content |
|---|---|---|
| 07:00 | daily-briefing | Weather + full day overview + meal plan |
| 10:00 | routine-snack1 | Mid-morning snack + hydration |
| 12:00 | routine-lunch | Lunch reminder + meal suggestion |
| 15:30 | routine-preworkout | Pre-workout fuel (training days) |
| 18:00 | routine-training | Workout plan (training days) |
| 19:30 | routine-dinner | Dinner reminder + post-workout nutrition |
| 22:00 | routine-winddown | Late snack + tomorrow preview |
