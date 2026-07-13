defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the embedded Kanban application.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns =
      assigns
      |> assign(:csrf_token, Plug.CSRFProtection.get_csrf_token())
      |> assign(:board_css_url, SymphonyElixirWeb.StaticAssets.board_css_url())
      |> assign(:favicon_url, SymphonyElixirWeb.StaticAssets.favicon_url())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Board</title>
        <link rel="icon" type="image/png" sizes="128x128" href={@favicon_url} />
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            var Hooks = {};

            Hooks.CopyValue = {
              mounted: function () {
                var button = this.el;
                var originalLabel = button.textContent;

                button.addEventListener("click", function () {
                  var value = button.dataset.copy;
                  if (!value || !navigator.clipboard) return;

                  navigator.clipboard.writeText(value).then(function () {
                    button.textContent = "Copied";
                    clearTimeout(button._copyTimer);
                    button._copyTimer = setTimeout(function () {
                      button.textContent = originalLabel;
                    }, 1200);
                  });
                });
              }
            };

            Hooks.Kanban = {
              mounted: function () {
                var dragged = null;

                this.el.addEventListener("dragstart", function (event) {
                  dragged = event.target.closest("[data-task-id]");
                  if (!dragged) return;
                  event.dataTransfer.effectAllowed = "move";
                  event.dataTransfer.setData("text/plain", dragged.dataset.taskId);
                  dragged.classList.add("dragging");
                });

                this.el.addEventListener("dragend", function () {
                  if (dragged) dragged.classList.remove("dragging");
                  dragged = null;
                });

                this.el.addEventListener("dragover", function (event) {
                  if (event.target.closest("[data-dropzone]")) event.preventDefault();
                });

                var hook = this;
                this.el.addEventListener("drop", function (event) {
                  var zone = event.target.closest("[data-dropzone]");
                  if (!zone || !dragged) return;
                  event.preventDefault();

                  if (dragged.dataset.active === "true" &&
                      !window.confirm("Stop the active run and move this task?")) return;

                  var neighbor = event.target.closest("[data-task-id]");
                  var payload = {
                    task_id: dragged.dataset.taskId,
                    expected_revision: dragged.dataset.taskRevision,
                    column_id: zone.dataset.dropzone
                  };

                  if (neighbor && neighbor !== dragged) {
                    var rect = neighbor.getBoundingClientRect();
                    if (event.clientY < rect.top + rect.height / 2) {
                      payload.after_task_id = neighbor.dataset.taskId;
                    } else {
                      payload.before_task_id = neighbor.dataset.taskId;
                    }
                  }

                  hook.pushEvent("move_task", payload);
                });
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              params: {_csrf_token: csrfToken},
              hooks: Hooks
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href={@board_css_url} />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
