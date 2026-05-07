# Project Memory MVP Dogfood Runbook

## Goal

Verify whether Project Memory can answer: "Before I resume a project, where did I leave off and what evidence supports that?"

## Setup

1. Build the app with `swift build`.
2. Run the app with `swift run ProjectMemoryApp`.
3. Open Settings and save an OpenRouter API key.
4. Choose one real active project folder that contains a Git repo and Markdown notes.
5. Import the folder from Sources.
6. Save 3-5 web captures related to the project.

## Daily Test

Before starting work, generate Today's brief and answer these questions:

- Does it correctly identify what changed recently?
- Does it mention sources I recognize?
- Does it avoid inventing facts?
- Does it suggest at least one useful next action?
- Does the Ask tab answer "这个项目我上次做到哪了？" better than my memory alone?

## Pass Criteria

- I open it at least 3 times in 7 days.
- At least 60% of briefs are worth reading.
- At least one answer saves 10+ minutes of context reconstruction.
- Wrong project/source assignment can be explained by missing or bad input, not random behavior.

## Notes Template

Date:
Project:
Brief usefulness, 1-5:
Best line:
Wrong or fabricated line:
Missing source:
Would I have paid for this moment:
