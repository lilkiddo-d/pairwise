export const metadata = { title: "Risk disclosure — Pairwise" };

export default function RiskPage() {
  return (
    <article className="prose">
      <h1>Risk disclosure</h1>
      <p className="lead">
        Pairwise is experimental, unaudited, open-source software. Using it can result in the loss of some or all of
        the funds you deposit. Nothing on this site is investment, legal or tax advice, and no one guarantees any
        return. Only deposit what you can afford to lose.
      </p>

      <h2>What the vaults do</h2>
      <p>
        Each vault trades one pair of tokenized stocks. When the ratio of their prices moves unusually far from its
        recent average (measured as a z-score of daily closes), the vault buys the relatively cheap token and borrows
        and sells the relatively expensive one in roughly equal dollar amounts, betting the ratio returns to normal.
        Market-neutral does not mean risk-free.
      </p>

      <h2>Strategy risks</h2>
      <ul>
        <li>
          <b>Correlation breakdown.</b> The two stocks can stop moving together (earnings, guidance, M&amp;A, index
          changes, regulation). The spread can keep widening; the vault then exits at its stop with a loss.
        </li>
        <li>
          <b>Model risk.</b> Z-scores, correlations and hedge ratios are estimated from a short window of daily closes.
          Past relationships do not guarantee future ones.
        </li>
        <li>
          <b>Gap risk.</b> Positions are only managed during US regular market hours. Prices can move sharply overnight,
          over weekends and on holidays, and stops can execute far from their thresholds.
        </li>
        <li>
          <b>Execution cost.</b> Every entry, exit, rebalance and in-position withdrawal swaps on decentralized exchanges.
          Fees and slippage reduce returns; withdrawals while a trade is open pay their own execution cost.
        </li>
      </ul>

      <h2>Short-leg risks</h2>
      <ul>
        <li>
          <b>Liquidation.</b> The short leg is a loan of stock tokens from a lending market, secured by USDG collateral.
          If the shorted stock rises enough, the loan can be liquidated with a penalty before the vault rebalances.
        </li>
        <li>
          <b>Borrow availability and cost.</b> Stock-token borrow liquidity on-chain is thin. Lenders can withdraw idle
          supply, interest rates can spike when utilization is high, and capacity limits how large positions can be.
        </li>
        <li>
          <b>Collateral vault risk.</b> Collateral may be held in a third-party USDG yield vault (ERC-4626). Its
          withdrawals depend on that vault&apos;s own liquidity and risk management.
        </li>
      </ul>

      <h2>Asset and infrastructure risks</h2>
      <ul>
        <li>
          <b>Tokenized stocks are not shares.</b> They are tokens issued by a third party that track a stock&apos;s price;
          they do not carry shareholder rights and depend on the issuer, its custodians and its corporate-action
          handling (e.g. dividend and split multipliers).
        </li>
        <li>
          <b>Stablecoin risk.</b> Vaults are denominated in USDG. A de-peg, freeze or blacklist would affect every vault.
        </li>
        <li>
          <b>Oracle risk.</b> Prices come from third-party oracle feeds. Stale, wrong or manipulated prices can cause bad
          entries, exits or valuations. The contracts reject stale data, which can also block withdrawals from vaults
          that hold a position.
        </li>
        <li>
          <b>Smart-contract and chain risk.</b> Bugs in Pairwise or in the protocols it uses (DEX, lending market, token
          contracts), and outages or reorganizations of the underlying network, can cause loss of funds.
        </li>
        <li>
          <b>Governance and keeper risk.</b> Parameters are changed by a 48-hour timelock; a guardian can pause and
          force-exit; keepers trigger trades. Their keys could be compromised or they could stop operating.
        </li>
      </ul>

      <h2>Legal</h2>
      <p>
        Tokenized securities and the services built around them are regulated differently in each jurisdiction and may
        be unavailable where you live. You are responsible for complying with your local laws. Access may be restricted
        in some regions. Pairwise is not affiliated with, endorsed by, or sponsored by any stock-token issuer, exchange,
        broker or the operator of the underlying network.
      </p>
    </article>
  );
}
