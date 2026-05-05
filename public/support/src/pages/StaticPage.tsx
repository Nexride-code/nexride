export function StaticPage({ title, body }: { title: string; body: string }) {
  return (
    <section>
      <h1>{title}</h1>
      <p>{body}</p>
    </section>
  );
}
