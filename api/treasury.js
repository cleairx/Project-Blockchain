// Live 3-month Treasury yield, fetched server side and cached at the edge.
//
// Runs as a Vercel Serverless Function at /api/treasury. Fetching here rather
// than from the page avoids two problems: neither upstream sends CORS headers,
// and a browser-side fetch would hammer them once per visitor.
//
// Cache-Control below pins the edge cache to six hours, so the figure the site
// shows is never more than six hours behind the published rate.

const SIX_HOURS = 21600;

// Last known good value, used only when both upstreams fail. Always labelled
// as a fallback in the response so the page never claims it is live.
const FALLBACK = { rate: 4.09, asOf: "2026-09-12", source: "fallback" };

// FRED publishes the daily 3-month constant maturity series as plain CSV with
// no API key. Missing days are written as ".", so walk backwards to the last
// numeric row rather than assuming the final line is usable.
async function fromFred() {
  const since = new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10);
  const res = await fetch(
    `https://fred.stlouisfed.org/graph/fredgraph.csv?id=DGS3MO&cosd=${since}`,
    { headers: { "User-Agent": "carry-rate/1.0" } }
  );
  if (!res.ok) throw new Error(`FRED ${res.status}`);

  const rows = (await res.text()).trim().split("\n").slice(1);
  for (let i = rows.length - 1; i >= 0; i--) {
    const parts = rows[i].split(",");
    const value = parseFloat(parts[1]);
    if (Number.isFinite(value)) {
      return { rate: value, asOf: parts[0].trim(), source: "FRED DGS3MO" };
    }
  }
  throw new Error("FRED returned no numeric observation");
}

// The Treasury's own daily par yield curve, as a second opinion. Parsed by
// regex deliberately: pulling in an XML library for two fields is not worth
// the dependency on a function that runs four times a day.
async function fromTreasury() {
  const year = new Date().getUTCFullYear();
  const res = await fetch(
    "https://home.treasury.gov/resource-center/data-chart-center/interest-rates/pages/xml" +
      `?data=daily_treasury_yield_curve&field_tdr_date_value=${year}`,
    { headers: { "User-Agent": "carry-rate/1.0" } }
  );
  if (!res.ok) throw new Error(`Treasury ${res.status}`);

  const xml = await res.text();
  const rates = [...xml.matchAll(/<d:BC_3MONTH[^>]*>([\d.]+)<\/d:BC_3MONTH>/g)];
  const dates = [...xml.matchAll(/<d:NEW_DATE[^>]*>([^<]+)<\/d:NEW_DATE>/g)];
  if (!rates.length) throw new Error("Treasury returned no BC_3MONTH field");

  const last = rates[rates.length - 1][1];
  const when = dates.length ? dates[dates.length - 1][1].slice(0, 10) : null;
  return { rate: parseFloat(last), asOf: when, source: "US Treasury par yield curve" };
}

module.exports = async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader(
    "Cache-Control",
    `public, max-age=0, s-maxage=${SIX_HOURS}, stale-while-revalidate=86400`
  );

  const errors = [];
  for (const source of [fromFred, fromTreasury]) {
    try {
      const out = await source();
      if (Number.isFinite(out.rate) && out.rate > 0 && out.rate < 25) {
        return res.status(200).json({ ...out, live: true, cachedForSeconds: SIX_HOURS });
      }
      errors.push(`${source.name}: implausible rate ${out.rate}`);
    } catch (err) {
      errors.push(`${source.name}: ${err.message}`);
    }
  }

  // Still answer 200. A stale benchmark should degrade the page, not break it.
  return res.status(200).json({ ...FALLBACK, live: false, errors, cachedForSeconds: SIX_HOURS });
};
