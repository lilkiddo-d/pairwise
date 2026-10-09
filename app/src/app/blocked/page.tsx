import Link from "next/link";

export const metadata = { title: "Unavailable in your region — Pairwise" };

export default function Blocked() {
  return (
    <div className="card narrow">
      <h1>Not available in your region</h1>
      <p>
        This interface is not offered in your jurisdiction. Tokenized securities are regulated differently around the
        world and we restrict access where required.
      </p>
      <p>
        <Link href="/risk">Read the risk disclosure</Link>
      </p>
    </div>
  );
}
