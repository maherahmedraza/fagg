## FAGG Product Roadmap — Sprint Plan

### Prioritization Framework

| Score | Impact | Criteria |
|-------|--------|----------|
| 🔴 P0 | Critical | Blocks daily workflow, safety risk, or top user request |
| 🟠 P1 | High | Significant productivity gain, competitive advantage |
| 🟡 P2 | Medium | Nice-to-have, improves experience |
| 🟢 P3 | Low | Future vision, strategic positioning |

---

### Sprint 1 — Foundation & Daily Workflow (Week 1–2)

| # | Feature | Priority | Effort | Value Justification |
|---|---------|----------|--------|-------------------|
| 1.1 | **`.faggrc` Config File** — Project-level defaults (`include`, `exclude`, `max-tokens`, `format`). Auto-discovered in project root or `~/.faggrc` | 🔴 P0 | 3 days | Eliminates retyping 10+ flags every run. Team consistency. Most requested feature pattern in CLI tools |
| 1.2 | **`--clipboard`** — Copy output to system clipboard after writing (`xclip`/`xsel`/`wl-copy`) | 🔴 P0 | 0.5 day | #1 workflow: aggregate → paste into ChatGPT. Saves open-file-copy-paste cycle every single use |
| 1.3 | **`--diff <branch>`** — Only aggregate files changed vs git branch (full file content, not patch) | 🔴 P0 | 2 days | Code review is the #1 use case. `--diff main` replaces manual cherry-picking. Massive token savings |
| 1.4 | **`--priority-boost <pattern>`** — Always include files matching glob regardless of recency/budget | 🟠 P1 | 1 day | Config files (`schema.prisma`, `package.json`, `tsconfig.json`) are rarely modified but always needed for context |
| 1.5 | **Secret Detection** — Regex scan for API keys, AWS secrets, tokens, passwords. Warn before writing output | 🔴 P0 | 2 days | Safety critical. One leaked key in aggregated output pasted to ChatGPT = security breach. Non-negotiable |
| | | | **~8.5 days** | |

**Sprint 1 Definition of Done:**
```bash
# User can do this after Sprint 1:
echo "include=ts,tsx,json" > .faggrc
echo "max-tokens=50000" >> .faggrc
fagg ./src out.txt --diff main --clipboard
# → Aggregates only changed files, warns about secrets, copies to clipboard
```

---

### Sprint 2 — Intelligence Layer (Week 3–4)

| # | Feature | Priority | Effort | Value Justification |
|---|---------|----------|--------|-------------------|
| 2.1 | **Dependency Chain** — Parse `import`/`require`/`from` statements. If `page.tsx` is selected, auto-include imported modules | 🟠 P1 | 4 days | Solves "LLM can't understand this file without its types/utils" problem. Transforms output quality |
| 2.2 | **Priority Scoring** — Rank files by: Recency (40%) + Import centrality (30%) + Token efficiency (30%). Use score for budget selection instead of pure mtime | 🟠 P1 | 3 days | Current mtime-only selection misses critical hub files. Scoring ensures `auth.ts` (imported 30x) beats `typo-fix.tsx` (modified 5 min ago) |
| 2.3 | **`--semantic-boundaries`** — Never split related files (detected via imports) across different output parts | 🟡 P2 | 2 days | When using `--split-tokens`, a component and its types ending up in different parts breaks LLM understanding |
| 2.4 | **Checksums** — SHA256 per file in output metadata (header/footer) | 🟡 P2 | 0.5 day | Integrity verification. Proves output matches source. Required for audit compliance |
| | | | **~9.5 days** | |

**Sprint 2 Definition of Done:**
```bash
fagg ./src out.txt --max-tokens 50000
# → Automatically includes UserService AND UserTypes because UserService imports UserTypes
# → Ranks files by smart score, not just modification date
# → Output includes SHA256 checksums
```

---

### Sprint 3 — LLM Optimization (Week 5–6)

| # | Feature | Priority | Effort | Value Justification |
|---|---------|----------|--------|-------------------|
| 3.1 | **Context Window Profiles** — `--profile gpt4` (128k), `--profile claude` (200k), `--profile gemini` (1M). Auto-sets `--max-tokens` and reserves 20% for response | 🟠 P1 | 1 day | Users don't know token limits. `--profile claude` is more intuitive than `--max-tokens 160000` |
| 3.2 | **Tiktoken Integration** — Optional exact token counting via Python bridge. Falls back to estimation if Python unavailable | 🟠 P1 | 3 days | Current ~4 chars/token has ±15% error. For tight budgets (50k), that's 7,500 tokens of waste or overflow |
| 3.3 | **`--patch-format`** — Output as unified diff instead of full files for `--diff` mode | 🟡 P2 | 2 days | 200-line file with 5-line change: full file = 200 lines of tokens. Patch = ~15 lines. 13x token savings |
| 3.4 | **`--minimize-redundancy`** — When splitting, extract shared dependencies to `_shared.txt` instead of duplicating across parts | 🟡 P2 | 3 days | `utils.ts` imported by 30 files shouldn't appear in every part. Extract once, reference everywhere |
| 3.5 | **`--header-only <N>`** — First N lines per file (for quick project overview within token budget) | 🟡 P2 | 0.5 day | Rapid codebase scanning: "Show me the first 20 lines of every file" for architecture understanding |
| | | | **~9.5 days** | |

**Sprint 3 Definition of Done:**
```bash
fagg ./src out.txt --profile claude --diff main --patch-format
# → Knows Claude's limit, reserves response space
# → Only changed files, as compact diffs
# → Exact token count if tiktoken available
```

---

### Sprint 4 — Developer Experience (Week 7–8)

| # | Feature | Priority | Effort | Value Justification |
|---|---------|----------|--------|-------------------|
| 4.1 | **Interactive Mode** — `--interactive` opens `fzf` multi-select with live token count preview. Select/deselect files, see budget impact in real-time | 🟠 P1 | 3 days | Power users want control. "I need these 5 specific files + whatever else fits" |
| 4.2 | **Watch Mode** — `--watch` auto-regenerate output when source files change (via `inotifywait`) | 🟡 P2 | 2 days | Long coding sessions: keep a terminal running `fagg --watch`, always have fresh context ready to paste |
| 4.3 | **License Headers** — Detect and optionally strip (`--strip-licenses`) or preserve license blocks | 🟡 P2 | 1.5 days | License blocks waste ~50-200 tokens per file. In 100-file aggregation = 5k-20k wasted tokens |
| 4.4 | **Audit Log** — Append-only `~/.fagg/audit.log` recording: timestamp, input dir, output file, files included, token count | 🟡 P2 | 1 day | Compliance: "What code was sent to external LLMs?" Enterprise security teams will require this |
| 4.5 | **`--token-heatmap`** — Show which files consume most tokens vs. git churn frequency | 🟢 P3 | 2 days | Identifies refactoring targets: "This 15k-token file changes every commit — worth splitting" |
| | | | **~9.5 days** | |

**Sprint 4 Definition of Done:**
```bash
fagg ./src out.txt --interactive --max-tokens 50000
# → Opens fzf picker showing:
#    [x] page.tsx          1,700 tok  (2 hours ago)
#    [x] auth.store.ts       750 tok  (yesterday)
#    [ ] package-lock.json 66,000 tok  (3 days ago)
#    Budget: 2,450 / 50,000 tokens
```

---

### Sprint 5 — AI-Native Features (Week 9–10)

| # | Feature | Priority | Effort | Value Justification |
|---|---------|----------|--------|-------------------|
| 5.1 | **Smart Summarization** — Files exceeding `--max-file-tokens` get LLM-generated summary instead of hard truncation. Uses local `ollama` or API | 🟡 P2 | 5 days | Hard truncation loses critical context at file end. Summary preserves intent: "This 500-line file handles user authentication with JWT refresh logic" |
| 5.2 | **`--compress-comments`** — Strip or summarize comment blocks to save tokens while preserving code | 🟡 P2 | 2 days | JSDoc comments on every function can consume 30% of file tokens. Strip them when token-constrained |
| 5.3 | **Profiles Directory** — `.fagg/profiles/code-review.conf`, `.fagg/profiles/onboarding.conf`, `.fagg/profiles/debugging.conf` | 🟡 P2 | 1.5 days | Different tasks need different configs. One-time setup, permanent productivity gain for whole team |
| 5.4 | **`--since-ref HEAD~5`** — Git ref-based time filtering (more precise than `--since date`) | 🟡 P2 | 1 day | "Last 5 commits" is more meaningful than "last 2 days" for code review context |
| | | | **~9.5 days** | |

---

### Sprint 6 — Enterprise & Scale (Week 11–14)

| # | Feature | Priority | Effort | Value Justification |
|---|---------|----------|--------|-------------------|
| 6.1 | **Parallel Processing** — GNU Parallel for file reading in monorepos (50k+ files) | 🟡 P2 | 3 days | Current sequential scan: 145s for stellapply. Parallel: ~15s. 10x improvement |
| 6.2 | **Incremental Cache** — SQLite DB tracking file hashes. Only re-read changed files | 🟡 P2 | 4 days | Repeated runs on same project: first run 30s, subsequent runs <2s |
| 6.3 | **Remote Sources** — `fagg git@github.com:org/repo.git` shallow-clone + aggregate without manual clone | 🟢 P3 | 3 days | Consultants auditing client repos. CI/CD pipelines generating docs |
| 6.4 | **VS Code Extension** — Right-click folder → "Aggregate for AI". GUI token budget slider | 🟢 P3 | 5 days | Largest developer audience. Removes CLI barrier for junior devs |
| 6.5 | **HTTP Server Mode** — `fagg serve --port 8080` — IDE plugins request context via API | 🟢 P3 | 4 days | Foundation for real-time IDE integration. Copilot-style "always-available context" |
| 6.6 | **Team Analytics** — Track which files are most frequently aggregated across team | 🟢 P3 | 3 days | Identifies documentation gaps: "Everyone keeps aggregating auth/ — needs better docs" |
| | | | **~22 days** | |

---

### Full Roadmap Summary

| Sprint | Theme | Key Deliverable | Business Value | Total Effort |
|--------|-------|----------------|---------------|-------------|
| **S1** | Foundation | `.faggrc`, `--clipboard`, `--diff`, secret scanning | Daily workflow 10x faster. Security baseline | ~8.5 days |
| **S2** | Intelligence | Import-aware selection, priority scoring | Output quality leap — LLM gets coherent context | ~9.5 days |
| **S3** | LLM Optimization | Profiles, tiktoken, patch format | Token efficiency ↑40%, zero waste | ~9.5 days |
| **S4** | Developer Experience | Interactive `fzf`, watch mode, audit log | Power user retention, enterprise compliance | ~9.5 days |
| **S5** | AI-Native | Smart summarization, comment compression | Handles edge cases that break basic tools | ~9.5 days |
| **S6** | Enterprise | Parallel, cache, remote, VS Code, server | Scale to monorepos, team adoption, monetization | ~22 days |

---

### Revenue Projection (If Monetized)

| Tier | Price | Features | Target |
|------|-------|----------|--------|
| **Free** | $0 | Core aggregation, filtering, token estimation, `.faggrc` | Individual devs, open-source adoption |
| **Pro** | $9/mo | Tiktoken exact counting, secret scanning, profiles, interactive mode, watch mode, smart summarization | Professional developers, freelancers |
| **Team** | $29/mo per seat | Shared configs, audit logs, analytics dashboard, priority support | Engineering teams (5-50 devs) |
| **Enterprise** | Custom | SSO/SAML, compliance reporting, on-prem deployment, SLA, remote sources, server mode | Large orgs (50+ devs), regulated industries |

```
Target: 10,000 free users → 500 Pro ($4,500/mo) → 50 Teams ($14,500/mo)
         → 5 Enterprise ($5,000/mo) = ~$24,000 MRR by Month 12
```

---

### Success Metrics per Sprint

| Sprint | Metric | Target |
|--------|--------|--------|
| S1 | Daily active commands | 100+ |
| S1 | Secrets caught before leak | Track count |
| S2 | Token efficiency (budget vs actual) | Within 5% |
| S2 | Files auto-included via dependency chain | 15-30% of output |
| S3 | Token estimation accuracy | ±3% (with tiktoken) |
| S4 | Interactive mode adoption | 40% of power users |
| S5 | Summarization quality (manual review) | 4/5 rating |
| S6 | Monorepo scan time reduction | 10x faster |
