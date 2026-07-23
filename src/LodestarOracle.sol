// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IFtsoV2} from "./interfaces/IFtsoV2.sol";
import {ILstRateProvider} from "./interfaces/ILstRateProvider.sol";

/// @title LodestarOracle
/// @notice USD valuation of collateral using Flare's enshrined FTSOv2 oracle.
/// @dev For direct feeds (FXRP -> XRP/USD) set rateProvider = address(0).
///      For LSTs (sFLR) set a feed on the underlying (FLR/USD) plus an sFLR->FLR rate provider.
contract LodestarOracle is Ownable2Step {
    struct Feed {
        bytes21 feedId; // FTSO feed id of the underlying asset (USD-denominated)
        address rateProvider; // optional: share->underlying rate (0 for 1:1 assets)
        uint8 tokenDecimals; // ERC20 decimals of the collateral token
        uint64 maxStale; // max age (seconds) of an FTSO update; mandatory, bounded to <= 1h
        uint16 haircutBps; // conservative discount on the reported value (0 = none, max 5000)
        bool set;
    }

    /// @dev Rate-limiter anchor for an LST's share->underlying rate. The VALUATION path clamps the
    ///      provider's reported rate to at most `anchor * (1 + growthBpsPerDay * elapsedDays)`, so a
    ///      compromised/upgraded rate provider (a trusted EXTERNAL contract, e.g. Sceptre's
    ///      single-EOA-upgradeable proxy) cannot instantly over-value collateral and mint
    ///      over-collateralized-looking loans. Decreases (a real slash) pass through UNCLAMPED —
    ///      under-valuing is always the conservative direction for lenders. Growth is linear from
    ///      the anchor; `pokeRateAnchor` (permissionless) ratchets the anchor forward at the clamped
    ///      value so legitimate staking yield keeps full headroom. Opt-in per collateral: until
    ///      `setRateClamp` arms it, behavior is byte-identical to the unclamped original.
    struct RateAnchor {
        uint192 rate; // last accepted rate (1e18); 0 = clamp not armed
        uint64 ts; // when the anchor was set
    }

    IFtsoV2 public immutable ftso;
    mapping(address => Feed) public feeds;
    mapping(address => RateAnchor) public rateAnchors;
    mapping(address => uint16) public rateGrowthBpsPerDay; // allowed upside slope while armed

    event FeedSet(address indexed token, bytes21 feedId, address rateProvider, uint64 maxStale, uint16 haircutBps);
    event RateClampSet(address indexed token, uint16 growthBpsPerDay, uint256 anchorRate);
    event RateAnchorPoked(address indexed token, uint256 anchorRate);

    error FeedNotSet();
    error StalePrice();
    error BadPrice();
    error BadParam();

    constructor(address _ftso, address _owner) Ownable(_owner) {
        ftso = IFtsoV2(_ftso);
    }

    /// @param maxStale max age (seconds) of an FTSO update; mandatory and bounded to <= 1 hour.
    /// @param haircutBps conservative discount applied to every reported value (<= 5000). Zero for
    ///        a 1:1-backed asset (FXRP≈XRP); non-zero for a wrapper that can trade under its
    ///        underlying (an LST under NAV), so LTV, the settlement floor, and impairment all use
    ///        realizable value, not par.
    function setFeed(address token, bytes21 feedId, address rateProvider, uint64 maxStale, uint16 haircutBps)
        external
        onlyOwner
    {
        // A staleness bound is mandatory: borrowing against a stale-high price is the one oracle
        // attack a lagged-but-live feed permits. FTSO updates every ~90s, so an hour is already
        // generous; anything longer has no legitimate use and is a crash-window over-borrow risk.
        if (maxStale == 0 || maxStale > 1 hours) revert BadParam();
        if (haircutBps > 5000) revert BadParam();
        feeds[token] = Feed(feedId, rateProvider, IERC20Metadata(token).decimals(), maxStale, haircutBps, true);
        emit FeedSet(token, feedId, rateProvider, maxStale, haircutBps);
    }

    /// @notice Arm (or re-arm) the rate clamp for an LST collateral, anchoring at the provider's
    ///         CURRENT rate. `growthBpsPerDay` bounds how fast the valuation rate may rise between
    ///         anchor updates (real LST yield is ~2 bps/day; 20 gives 10x headroom while capping a
    ///         provider compromise to +0.2%/day). Pass 0 to DISARM (returns to unclamped behavior).
    /// @dev Owner-only and deliberate: re-arming anchors at the RAW provider rate, so if the anchor
    ///      went stale during a long clamp-neglect the owner can re-baseline — the same trust level
    ///      as setFeed itself. Routine forward movement should use the permissionless poke instead.
    function setRateClamp(address token, uint16 growthBpsPerDay) external onlyOwner {
        Feed memory f = feeds[token];
        if (!f.set || f.rateProvider == address(0)) revert BadParam();
        if (growthBpsPerDay == 0) {
            delete rateAnchors[token];
            delete rateGrowthBpsPerDay[token];
            emit RateClampSet(token, 0, 0);
            return;
        }
        if (growthBpsPerDay > 500) revert BadParam(); // >5%/day allowance defeats the point
        uint256 rate = ILstRateProvider(f.rateProvider).underlyingPerShare();
        // 0 and >uint192 are both provider malfunctions; a silent uint192 truncation would anchor
        // at a tiny value and clamp all valuations toward zero.
        if (rate == 0 || rate > type(uint192).max) revert BadPrice();
        rateAnchors[token] = RateAnchor(uint192(rate), uint64(block.timestamp));
        rateGrowthBpsPerDay[token] = growthBpsPerDay;
        emit RateClampSet(token, growthBpsPerDay, rate);
    }

    /// @notice Ratchet an armed clamp's anchor to the CURRENT CLAMPED rate (permissionless — a
    ///         keeper calls this periodically). Because the new anchor is the clamped value, a
    ///         spiked provider can only advance the anchor along the allowed slope, never jump it;
    ///         a decreased rate (slash) lowers the anchor immediately.
    function pokeRateAnchor(address token) external {
        Feed memory f = feeds[token];
        if (!f.set || f.rateProvider == address(0)) revert BadParam();
        if (rateAnchors[token].rate == 0) revert BadParam(); // not armed
        uint256 raw = ILstRateProvider(f.rateProvider).underlyingPerShare();
        if (raw == 0) revert BadPrice();
        uint256 accepted = _clampedRate(token, raw);
        rateAnchors[token] = RateAnchor(uint192(accepted), uint64(block.timestamp));
        emit RateAnchorPoked(token, accepted);
    }

    /// @dev min(raw, anchor + anchor * growth * elapsed). Unarmed (anchor 0) passes raw through.
    function _clampedRate(address token, uint256 raw) internal view returns (uint256) {
        RateAnchor memory a = rateAnchors[token];
        if (a.rate == 0) return raw;
        uint256 allowed = uint256(a.rate)
            + (uint256(a.rate) * rateGrowthBpsPerDay[token] * (block.timestamp - a.ts)) / (10_000 * 1 days);
        return raw > allowed ? allowed : raw;
    }

    /// @notice USD price of one whole token, scaled to 1e18.
    function priceUsd18(address token) public view returns (uint256) {
        Feed memory f = feeds[token];
        if (!f.set) revert FeedNotSet();
        (uint256 value, int8 dec, uint64 ts) = ftso.getFeedById(f.feedId);
        if (value == 0) revert BadPrice();
        if (f.maxStale != 0 && block.timestamp > uint256(ts) + f.maxStale) revert StalePrice();

        uint256 price18 = _to18(value, dec);
        if (f.rateProvider != address(0)) {
            uint256 rate = ILstRateProvider(f.rateProvider).underlyingPerShare(); // 1e18
            if (rate == 0) revert BadPrice();
            // Valuation-side rate limiter (see RateAnchor). Only the VALUATION is clamped: rateOf()
            // stays raw because the loan book's yield-skim applies its own +20% clamp and skimming
            // less than reality only ever favours the borrower.
            rate = _clampedRate(token, rate);
            price18 = (price18 * rate) / 1e18;
        }
        // Apply the conservative haircut so every downstream risk decision (LTV, settlement
        // floor, impairment) uses realizable value rather than par for wrappers that can trade
        // under their underlying.
        if (f.haircutBps != 0) price18 = (price18 * (10_000 - f.haircutBps)) / 10_000;
        // Guard the *scaled* price, not just the raw feed value: a feed whose decimals exceed
        // 18 enough to floor to zero would otherwise pass as a legitimate (mispriced) zero.
        if (price18 == 0) revert BadPrice();
        return price18;
    }

    /// @notice USD value (1e18) of `amount` raw units of `token`.
    function usdValue18(address token, uint256 amount) external view returns (uint256) {
        Feed memory f = feeds[token];
        if (!f.set) revert FeedNotSet();
        uint256 p = priceUsd18(token);
        return (p * amount) / (10 ** f.tokenDecimals);
    }

    /// @notice Current share->underlying rate of `token` (1e18-scaled); 1e18 if it has no LST rate.
    /// @dev Used by the loan book to measure staking appreciation between open and repay.
    function rateOf(address token) external view returns (uint256) {
        address rp = feeds[token].rateProvider;
        return rp == address(0) ? 1e18 : ILstRateProvider(rp).underlyingPerShare();
    }

    function _to18(uint256 value, int8 dec) internal pure returns (uint256) {
        int256 diff = int256(18) - int256(dec);
        if (diff >= 0) return value * (10 ** uint256(diff));
        return value / (10 ** uint256(-diff));
    }
}
