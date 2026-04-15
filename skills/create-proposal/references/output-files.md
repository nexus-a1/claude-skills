# Output Files Summary

Directory structure for an example proposal with identifier `AUTH-001` and name `user-authentication`.

## Work Directory (during development)

```
$WORK_DIR/AUTH-001/
├── state.json       # State tracking for resume
├── context/
│   ├── requirements.json     # Phase 1 agent output
│   └── approaches.json       # Phase 2 agent output
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
