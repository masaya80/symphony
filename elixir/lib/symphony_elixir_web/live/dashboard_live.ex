defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Config
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:custom_name, Config.custom_name())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony オブザーバビリティ
            </p>
            <h1 class="hero-title">
              <%= @custom_name || "オペレーションダッシュボード" %>
            </h1>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              ライブ
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              オフライン
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            スナップショット取得不可
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">実行中</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">現在のランタイムにおけるアクティブなイシューセッション数。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">リトライ中</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">次のリトライウィンドウを待機中のイシュー数。</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">総トークン数</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              入力 <%= format_int(@payload.codex_totals.input_tokens) %> / 出力 <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">ランタイム</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">完了済みおよびアクティブなセッション全体の Codex ランタイム合計。</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">レート制限</h2>
              <p class="section-copy">利用可能な場合、最新のアップストリームレート制限スナップショット。</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">実行中のセッション</h2>
              <p class="section-copy">アクティブなイシュー、最終エージェントアクティビティ、トークン使用量。</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">アクティブなセッションはありません。</p>
          <% else %>
            <div class="session-card-list">
              <article :for={entry <- @payload.running} class="session-card">
                <div class="session-card-header">
                  <div class="session-card-title">
                    <span class="issue-id"><%= entry.issue_identifier %></span>
                    <span class={state_badge_class(entry.state)}><%= entry.state %></span>
                    <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON 詳細</a>
                  </div>
                  <div class="session-card-runtime numeric">
                    <span class="session-runtime-value"><%= format_runtime_seconds(runtime_seconds_from_started_at(entry.started_at, @now)) %></span>
                    <%= if is_integer(entry.turn_count) and entry.turn_count > 0 do %>
                      <span class="muted session-runtime-turns">/ <%= entry.turn_count %> ターン</span>
                    <% end %>
                  </div>
                </div>

                <div class="session-meta-grid">
                  <div class="session-meta-item">
                    <span class="session-meta-label">セッション ID</span>
                    <span class="session-meta-value">
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="ID をコピー"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'コピー完了'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          ID をコピー
                        </button>
                      <% else %>
                        <span class="muted">なし</span>
                      <% end %>
                    </span>
                  </div>

                  <div class="session-meta-item">
                    <span class="session-meta-label">ワーカーホスト</span>
                    <span class="session-meta-value mono"><%= entry.worker_host || "なし" %></span>
                  </div>

                  <%= if entry.workspace_path do %>
                    <div class="session-meta-item session-meta-item-wide">
                      <span class="session-meta-label">ワークスペース</span>
                      <span class="session-meta-value mono session-path"><%= entry.workspace_path %></span>
                    </div>
                  <% end %>
                </div>

                <div class="session-event-row">
                  <div class="session-event-body">
                    <span class="session-meta-label">最終 Codex 更新</span>
                    <span
                      class="event-text"
                      title={entry.last_message || to_string(entry.last_event || "なし")}
                    ><%= entry.last_message || to_string(entry.last_event || "なし") %></span>
                    <span class="muted event-meta">
                      <%= entry.last_event || "なし" %>
                      <%= if entry.last_event_at do %>
                        · <span class="mono numeric"><%= entry.last_event_at %></span>
                      <% end %>
                    </span>
                  </div>
                </div>

                <div class="session-token-row numeric">
                  <div class="session-token-item">
                    <span class="session-meta-label">合計トークン</span>
                    <span class="session-token-value"><%= format_int(entry.tokens.total_tokens) %></span>
                  </div>
                  <div class="session-token-item">
                    <span class="session-meta-label">入力</span>
                    <span class="session-token-value muted"><%= format_int(entry.tokens.input_tokens) %></span>
                  </div>
                  <div class="session-token-item">
                    <span class="session-meta-label">出力</span>
                    <span class="session-token-value muted"><%= format_int(entry.tokens.output_tokens) %></span>
                  </div>
                </div>
              </article>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">リトライキュー</h2>
              <p class="section-copy">次のリトライウィンドウを待機中のイシュー。</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">現在バックオフ中のイシューはありません。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>イシュー</th>
                    <th>試行回数</th>
                    <th>実行予定時刻</th>
                    <th>エラー</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON 詳細</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "なし" %></td>
                    <td><%= entry.error || "なし" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
