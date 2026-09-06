# Project Notes

Working file. Read this first to understand where the project stands.

## What this is

A tokenized money market fund on Solidity. Investors subscribe stablecoins and
receive fund shares. The share value (NAV per share) accrues over time as the
underlying T-bills earn yield. Shares can only be held by whitelisted addresses,
because they represent a security.

Mirrors the structure of real products like BlackRock's BUIDL and Franklin
Templeton's FOBXX, where a transfer agent maintains an eligible-holder list and
the blockchain acts as the official share register.

Testnet only. Base Sepolia. Not a real fund, no real money.

## Design decisions

**Yield-bearing, not rebasing.** NAV per share rises over time; share count stays
fixed. The alternative (rebasing) holds price at $1.00 and adjusts balances
instead. Rebasing suits DAO treasuries and DeFi collateral that need a stable
unit; yield-bearing suits investors focused on accumulation and tax treatment.
Chose yield-bearing because the accounting is cleaner to reason about and to test.

**Decimals: 6 for both the asset and the shares.** USDC uses 6 decimals, so
matching the share token to it keeps subscribe/redeem math free of scaling
conversions. NAV per share is tracked separately as an 18-decimal fixed-point
number, where 1e18 represents exactly $1.00.

**Accrual is simple interest, not compound.** NAV grows linearly with elapsed
time against a stored annual rate. Real money market funds accrue daily on a
simple basis, so this matches them and the arithmetic can be checked by hand.

**Rising NAV must be funded.** A NAV that rises on its own is only a promise —
the contract would owe redeemers more than it holds, and late redeemers could
not exit. `depositYield` is how the manager pays the interest in, mirroring
T-bill coupon proceeds settling. `isFullyBacked` reports whether the promise is
currently covered. There is a test for the failure case, not just the happy one.

**Whitelist over full ERC-3643.** A single mapping checked on transfer captures
the concept (transfer restriction on a security) without the weight of
implementing the whole standard. Documented as a deliberate scope choice.

## Status

- [x] Repo structure
- [x] Foundry + OpenZeppelin v5.7.0 installed, `forge build` passing
- [x] Mock USDC (test asset)
- [x] Core contract: ERC-20 shares, subscribe, redeem
- [x] NAV accrual over time (simple interest from an annual rate)
- [x] Yield funding via `depositYield`, plus `isFullyBacked` view
- [x] Whitelist / compliance layer gated through the v5 `_update` hook
- [x] Admin controls: freeze, force-transfer, COMPLIANCE_ROLE
- [x] Foundry tests — 24 passing
- [x] README with architecture diagram
- [x] Deploy script and `.env.example`
- [ ] Deploy to Base Sepolia, record the address in the README
- [ ] Walkthrough video

## Next session

All contract work is finished and verified. Nothing left to code. Two jobs:
put it on a live testnet, and record the video.

### Deploying, step by step

1. Make a throwaway wallet — `cast wallet new`. Never use a wallet holding
   real funds, and never paste the private key anywhere but `.env`.
2. Fund it with test ETH from a Base Sepolia faucet:
   https://docs.base.org/chain/network-faucets
3. `cp .env.example .env`, then put the private key in it. `.env` is
   gitignored and must stay that way.
4. Deploy:
   ```
   source .env
   forge script script/Deploy.s.sol:Deploy --rpc-url base_sepolia --broadcast
   ```
5. Paste the printed `TokenizedFund` address into the README, replacing
   "not yet deployed".
6. Do one live `subscribe` against the deployed contract, so there is a real
   transaction to point at in the video.

### Then the video

Two minutes. Suggested beats: what a tokenized money market fund is, why NAV
rises instead of the balance, why a rising NAV has to be funded, and why the
transfer agent needs `forceTransfer`.

### Housekeeping

All work sits on branch `claude/claude-code-blockchain-setup-x2gfc6`, not on
`main`. Merge it when ready — "Squash and merge" collapses it into a single
commit whose message is editable before confirming.

Priority if time runs short: tests matter more than features. A smaller
tested contract beats a larger untested one.

## Open questions to resolve

- Management fee: include or leave out of scope? (Real funds charge 0.2-0.5%)
- Redemption: instant, or add a queue to model real settlement delay?
- Should `depositYield` be callable by anyone, or stay admin-only? Admin-only
  today, which mirrors a manager settling T-bill proceeds.

## Glossary

- **NAV** - Net Asset Value. Total fund value divided by shares outstanding.
- **Subscribe** - Deposit assets, receive newly issued shares.
- **Redeem** - Return shares, receive assets back.
- **Transfer agent** - The entity maintaining the official shareholder register
  and controlling who is allowed to hold shares.
- **ERC-20** - The standard interface every fungible token on Ethereum follows.
