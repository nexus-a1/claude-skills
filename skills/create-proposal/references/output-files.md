# Output Files Summary

Directory structure for an example proposal with ticket `AUTH-001` and name `user-authentication`, so identifier `AUTH-001-user-authentication`.

## Work Directory (during development)

```
$WORK_DIR/AUTH-001-user-authentication/
├── state.json       # State tracking for resume
├── context/
│   ├── requirements.json     # Phase 1 business-analyst output
│   ├── exploration.md        # Phase 1 Explore output
│   ├── approaches.json       # Phase 2 Plan output
│   ├── architecture-validation.md  # Phase 2 architect output
│   └── quality-guard.md      # Phase 3.5 review
├── notes/
│   ├── requirements.md       # Human-readable requirements
│   ├── questions.md          # Clarifications gathered
│   └── decisions.md          # Design decisions
├── proposal1.md              # Initial design
├── proposal2.md              # Refined design
├── src/                      # Implementation (after approval)
│   ├── Controller/
│   ├── Service/
│   ├── Entity/
│   └── ...
└── README.md                 # Final documentation
```

## Final Output (on completion)

```
$PROPOSALS_DIR/user-authentication/
├── proposal-final.md         # Approved proposal
├── README.md                 # Installation guide
├── notes/                    # Design context
└── src/                      # Implementation code
```
