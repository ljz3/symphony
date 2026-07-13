defmodule SymphonyElixirWeb.ArchiveLive do
  @moduledoc "Archived task tombstones."

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Board

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Board.subscribe(:tasks)
    {:ok, assign(socket, :tasks, Board.tasks(archived: true))}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, assign(socket, :tasks, Board.tasks(archived: true))}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="detail-page">
      <header class="topbar"><div><a href="/" class="back-link">← Board</a><p class="eyebrow">Tombstones</p><h1>Archive</h1></div></header>
      <nav class="archive-actions"><a href="/stats" class="button secondary">Stats</a></nav>
      <section class="detail-card archive-list">
        <p :if={@tasks == []} class="empty">No archived tasks.</p>
        <article :for={task <- @tasks} class="archive-row">
          <div><strong>{task.identifier}</strong><a href={"/tasks/#{task.identifier}"}>{task.title}</a></div>
          <span>{task.column_id}</span><time>{task.archived_at}</time>
        </article>
      </section>
    </section>
    """
  end
end
