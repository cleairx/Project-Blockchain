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

1. Deploy to Base Sepolia and paste the contract address into the README
2. Do one live subscribe on the testnet, to have something to show
3. Record the walkthrough video

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
