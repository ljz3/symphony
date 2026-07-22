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

            Hooks.HoverPeek = {
              mounted: function () {
                var card = this.el;
                var popover = card.querySelector(".peek-popover");
                if (!popover) return;
                var showTimer = null;

                var hide = function () {
                  clearTimeout(showTimer);
                  showTimer = null;
                  popover.hidden = true;
                };

                card.addEventListener("mouseenter", function () {
                  if (showTimer) return;
                  showTimer = setTimeout(function () {
                    var rect = card.getBoundingClientRect();
                    popover.hidden = false;
                    var width = popover.offsetWidth;
                    var left = rect.right + 10;
                    if (left + width > window.innerWidth - 8) {
                      left = Math.max(8, rect.left - width - 10);
                    }
                    var top = Math.min(rect.top, window.innerHeight - popover.offsetHeight - 8);
                    popover.style.left = left + "px";
                    popover.style.top = Math.max(8, top) + "px";
                  }, 450);
                });
                card.addEventListener("mouseleave", hide);
                card.addEventListener("dragstart", hide);
                card.addEventListener("contextmenu", hide);
              },
              destroyed: function () {
                var popover = this.el.querySelector(".peek-popover");
                if (popover) popover.hidden = true;
              }
            };

            Hooks.Kanban = {
              mounted: function () {
                var dragged = null;
                var hook = this;

                // --- Card context menu (right-click) ---
                var menu = null;

                var closeMenu = function () {
                  if (menu) {
                    menu.remove();
                    menu = null;
                  }
                };

                var menuButton = function (label, onClick) {
                  var button = document.createElement("button");
                  button.type = "button";
                  button.textContent = label;
                  button.addEventListener("click", function () {
                    closeMenu();
                    onClick();
                  });
                  return button;
                };

                var copyValue = function (value) {
                  if (value && navigator.clipboard) navigator.clipboard.writeText(value);
                };

                var openMenu = function (event, card) {
                  closeMenu();
                  menu = document.createElement("div");
                  menu.className = "context-menu";

                  menu.appendChild(menuButton("Open peek", function () {
                    hook.pushEvent("open_peek", {identifier: card.dataset.identifier});
                  }));
                  menu.appendChild(menuButton("Open full page", function () {
                    window.location.href = "/tasks/" + card.dataset.identifier;
                  }));
                  menu.appendChild(menuButton("Copy identifier", function () {
                    copyValue(card.dataset.identifier);
                  }));
                  menu.appendChild(menuButton("Copy branch", function () {
                    copyValue(card.dataset.branch);
                  }));
                  if (card.dataset.prUrl) {
                    menu.appendChild(menuButton("Copy PR link", function () {
                      copyValue(card.dataset.prUrl);
                    }));
                  }

                  var moves = [];
                  try { moves = JSON.parse(card.dataset.moves || "[]"); } catch (error) { moves = []; }
                  if (moves.length > 0) {
                    var separator = document.createElement("div");
                    separator.className = "context-menu-sep";
                    menu.appendChild(separator);
                    var label = document.createElement("p");
                    label.className = "context-menu-label";
                    label.textContent = "Move to";
                    menu.appendChild(label);
                    moves.forEach(function (move) {
                      menu.appendChild(menuButton(move.name, function () {
                        if (card.dataset.active === "true" &&
                            !window.confirm("Stop the active run and move this task?")) return;
                        hook.pushEvent("move_task", {
                          task_id: card.dataset.taskId,
                          expected_revision: card.dataset.taskRevision,
                          column_id: move.id
                        });
                      }));
                    });
                  }

                  document.body.appendChild(menu);
                  var left = Math.min(event.clientX, window.innerWidth - menu.offsetWidth - 8);
                  var top = Math.min(event.clientY, window.innerHeight - menu.offsetHeight - 8);
                  menu.style.left = Math.max(8, left) + "px";
                  menu.style.top = Math.max(8, top) + "px";
                };

                this.el.addEventListener("contextmenu", function (event) {
                  var card = event.target.closest("[data-task-id]");
                  if (!card) return;
                  event.preventDefault();
                  openMenu(event, card);
                });
                document.addEventListener("click", closeMenu);
                document.addEventListener("keydown", function (event) {
                  if (event.key === "Escape") closeMenu();
                });
                window.addEventListener("blur", closeMenu);
                this.el.addEventListener("scroll", closeMenu);

                // --- Drag and drop ---
                this.el.addEventListener("dragstart", function (event) {
                  closeMenu();
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
