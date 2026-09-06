# Project context for Claude Code

Read this first. It carries over context from a prior chat session.

## Who I'm working with

Junsu — a **finance student, not a computing student**. Building this as a portfolio
project for an overseas internship application (NOC) targeting New York digital asset
and tokenization roles. Wants to genuinely learn Solidity, not just ship code.

**How to work with him:**

- Explain like he's 15. Short sentences. One concept at a time.
- **When he asks about a word, always say what category it is first** — keyword,
  type, name we invented, imported from OpenZeppelin, or built-in global. He found
  this framing genuinely useful.
- Don't dump long explanations unprompted. He asks follow-ups; wait for them.
- Finance analogies land well. Code analogies mostly don't.
- Explain what a command does before he runs it, not after.
- He gets frustrated when given half-instructions across many messages. Give one
  complete block to run.

## What we're building

A **tokenized money market fund**. Investors deposit a stablecoin and receive shares.
NAV per share rises over time as the underlying T-bills earn yield. Share count stays
fixed; the price moves. Transfers will be restricted to whitelisted addresses, because
the shares represent a security.

Modeled on BlackRock's BUIDL and Franklin Templeton's FOBXX. Testnet only (Base
Sepolia). Not a real fund.

**Why this project:** the differentiator is finance knowledge, not engineering. NAV
accrual, transfer agent function, Reg D-style holder gating. A strong CS student would
build this incorrectly because they don't know what a transfer agent does.

## Environment

- Windows, VS Code, Git Bash terminal
- Foundry installed (`forge`, `cast`, `anvil`, `chisel`)
- OpenZeppelin v5.7.0 in `lib/`
- `forge build` passing
- Repo: github.com/cleairx/Project-Blockchain

## What already exists

**`src/MockUSDC.sol`** — fake USDC for testing. 6 decimals, open `mint` faucet.

**`src/TokenizedFund.sol`** — the fund. `ERC20` + `AccessControl`. Three functions:
- `subscribe(assetAmount)` — stablecoin in, shares out at current NAV
- `redeem(shareAmount)` — shares in, stablecoin out at current NAV
- `updateNav(newNav)` — admin raises the share price (guarded by `NAV_UPDATER_ROLE`)

Plus two view functions: `balanceInAssets`, `totalAssetsUnderManagement`.

He has read both files line by line and understands them at a working level. There
are parts he doesn't fully grasp yet and that's accepted — he plans to take proper
Solidity courses later.

## Design decisions already made

**Yield-bearing, not rebasing.** NAV rises; balances stay fixed.

**6 decimals for both asset and shares**, matching real USDC, so subscribe/redeem
needs no rescaling. NAV tracked separately as 18-decimal fixed point where
`1e18` == $1.00.

**Simple whitelist over full ERC-3643.** Captures the concept without the weight.
Deliberate scope choice, should be documented as such in the README.

## Next session plan (3 hours)

1. **NAV accrual over time** (~45 min) — replace manual `updateNav` with time-based
   calculation from a stored annual yield rate. Then write tests for it (~30 min).
2. **Whitelist / compliance layer** (~60 min) — gate transfers to approved addresses,
   add freeze and force-transfer admin powers. Then tests (~30 min).

**If time runs short, cut features and keep tests.** A smaller tested contract beats
a larger untested one. Target 10-12 tests total.

## Still remaining after that

- Deploy to Base Sepolia, get a live contract address
- README with architecture diagram, contract address, run instructions
- Two-minute walkthrough video

## Working habits

- Commit and push after each meaningful chunk. Never leave a day's work unpushed.
- Keep `NOTES.md` current — it's the status file.
- Explain the *why* behind each new construct as it's introduced. He's here to learn.
