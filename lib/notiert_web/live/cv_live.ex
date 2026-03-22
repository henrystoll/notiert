defmodule NotiertWeb.CvLive do
  @moduledoc """
  Main LiveView for the notiert living CV.

  Renders the CV, manages per-visitor session state, and coordinates
  the director agent loop that rewrites content in real-time.
  """
  use NotiertWeb, :live_view

  alias Notiert.Director.Session

  @impl true
  def mount(params, _session, socket) do
    debug? = Map.has_key?(params, "debug")

    socket =
      socket
      |> assign(
        debug: debug?,
        phase: 0,
        session_id: nil,
        # CV section content - original values
        sections: default_sections(),
        # Mutations applied by director (section_id => new content)
        mutations: %{},
        # Margin notes (section_id => %{content, author})
        margin_notes: %{},
        # Visual overrides (CSS variable => value)
        visual_overrides: %{},
        # Ghost cursor state
        ghost_cursor: nil,
        # Toolbar visibility
        toolbar_visible: false,
        # Viewer avatars
        viewer_you_visible: false,
        viewer_ghost_visible: false,
        # Typing animation queue
        typing: nil
      )

    if connected?(socket) do
      session_id = generate_session_id()

      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Notiert.SessionSupervisor,
          {Session, %{session_id: session_id, live_view_pid: self()}}
        )

      {:ok,
       assign(socket, session_id: session_id)
       |> push_event("session_started", %{session_id: session_id})}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("fingerprint", fingerprint, socket) do
    if socket.assigns.session_id do
      Session.update_fingerprint(socket.assigns.session_id, fingerprint)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("behavior", behavior, socket) do
    if socket.assigns.session_id do
      Session.update_behavior(socket.assigns.session_id, behavior)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("permission_result", %{"permission" => perm, "result" => result} = data, socket) do
    if socket.assigns.session_id do
      Session.update_permission(socket.assigns.session_id, perm, result, data)
    end

    {:noreply, socket}
  end

  # Director action callbacks from the Session process
  @impl true
  def handle_info({:director_action, action}, socket) do
    socket = apply_director_action(action, socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:phase_change, phase}, socket) do
    socket =
      socket
      |> assign(phase: phase)
      |> maybe_show_toolbar(phase)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp apply_director_action(%{"tool" => "rewrite_section"} = action, socket) do
    section_id = action["section_id"]
    content = action["content"]
    tone = action["tone"] || "subtle"
    typing_speed = action["typing_speed"] || "normal"

    mutations = Map.put(socket.assigns.mutations, section_id, content)

    socket
    |> assign(mutations: mutations)
    |> push_event("type_rewrite", %{
      section_id: section_id,
      content: content,
      tone: tone,
      typing_speed: typing_speed,
      debug: socket.assigns.debug
    })
  end

  defp apply_director_action(%{"tool" => "add_margin_note"} = action, socket) do
    section_id = action["anchor_section"]
    note = %{content: action["content"], author: action["author_name"] || "notiert"}

    margin_notes = Map.put(socket.assigns.margin_notes, section_id, note)

    socket
    |> assign(margin_notes: margin_notes)
    |> push_event("show_margin_note", %{
      section_id: section_id,
      content: note.content,
      author: note.author
    })
  end

  defp apply_director_action(%{"tool" => "adjust_visual"} = action, socket) do
    css_vars = action["css_variables"] || %{}
    duration = action["transition_duration_ms"]
    target = action["target"] || "global"

    visual_overrides = Map.merge(socket.assigns.visual_overrides, css_vars)

    socket
    |> assign(visual_overrides: visual_overrides)
    |> push_event("adjust_visual", %{
      css_variables: css_vars,
      transition_duration_ms: duration,
      target: target
    })
  end

  defp apply_director_action(%{"tool" => "show_ghost_cursor"} = action, socket) do
    ghost = %{
      label: action["cursor_label"],
      behavior: action["behavior"],
      target: action["target"]
    }

    socket
    |> assign(ghost_cursor: ghost)
    |> push_event("show_ghost_cursor", %{
      cursor_label: ghost.label,
      behavior: ghost.behavior,
      target: ghost.target
    })
  end

  defp apply_director_action(%{"tool" => "request_browser_permission"} = action, socket) do
    push_event(socket, "request_permission", %{
      permission: action["permission"],
      pre_request_content: action["pre_request_content"],
      on_granted_content: action["on_granted_content"],
      on_denied_content: action["on_denied_content"],
      target_section: action["target_section"]
    })
  end

  defp apply_director_action(%{"tool" => "do_nothing"}, socket), do: socket

  defp apply_director_action(_unknown, socket), do: socket

  defp maybe_show_toolbar(socket, phase) when phase >= 2 do
    socket
    |> assign(toolbar_visible: true, viewer_you_visible: true)
    |> then(fn s ->
      if phase >= 3, do: assign(s, viewer_ghost_visible: true), else: s
    end)
  end

  defp maybe_show_toolbar(socket, _phase), do: socket

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp default_sections do
    %{
      "about" =>
        "Data Scientist at Danske Bank working on agentic AI systems, LLM observability, and responsible AI in regulated financial services. Building under an Agentic Development Life Cycle (ADLC) framework. External lecturer at Copenhagen Business School, teaching programming for the MSc in Business Administration and Data Science programme. Background spanning SAP consulting, AI project leadership, supply chain management, and United Nations work.",
      "experience" => [
        %{
          role: "Product Owner / Data Scientist",
          company: "Danske Bank, Copenhagen",
          period: "2023–Present",
          description:
            "Leading agentic AI initiatives in a regulated banking environment. Designing LLM observability infrastructure with LangSmith/Langfuse. Building multi-agent credit decisioning systems. Navigating the intersection of innovation and compliance."
        },
        %{
          role: "External Lecturer",
          company: "Copenhagen Business School",
          period: "2026–Present",
          description:
            "Teaching Computational Intelligence for Business to MSc students. Curriculum design emphasising hacker mindset pedagogy with progressive portfolio assessment and real-world data infrastructure."
        },
        %{
          role: "AI & Technology Consultant",
          company: "Various, International",
          period: "2018–2023",
          description:
            "SAP consulting (technical through board-level), blockchain project leadership, cross-platform app development, supply chain optimisation, United Nations advisory work."
        }
      ],
      "skills" => [
        "Python",
        "Elixir",
        "TypeScript",
        "Kubernetes",
        "LLM Orchestration",
        "LangChain/LangSmith",
        "AWS Bedrock",
        "Talos Linux",
        "Cilium/Flux GitOps",
        "SAP",
        "German",
        "Danish"
      ],
      "projects" => [
        %{
          name: "Homelab Infrastructure",
          description:
            "Kubernetes cluster on Hetzner Cloud running Talos Linux with Cilium CNI and Flux GitOps. Because renting compute is fine but owning the control plane is better."
        },
        %{
          name: "notiert",
          description:
            "This website. A living CV that watches its visitors and rewrites itself in real-time using an LLM director agent. You are experiencing it right now."
        }
      ],
      "education" =>
        "MSc Business Administration & Data Science — Copenhagen Business School"
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="notiert-app" phx-hook="Notiert" data-debug={to_string(@debug)}>
      <%!-- Google Docs-style toolbar --%>
      <div id="toolbar" class={"toolbar #{if @toolbar_visible, do: "visible", else: ""}"}>
        <div class="toolbar-inner">
          <span class="doc-title">Henry Stoll — Curriculum Vitae</span>
          <div class="viewer-avatars">
            <div class={"viewer-avatar viewer-you #{if @viewer_you_visible, do: "visible", else: ""}"} title="You">
              ?
            </div>
            <div class={"viewer-avatar viewer-ghost #{if @viewer_ghost_visible, do: "visible", else: ""}"} title="notiert">
              N
            </div>
          </div>
        </div>
      </div>

      <%!-- Ghost cursor --%>
      <div id="ghost-cursor" class={"ghost-cursor #{if @ghost_cursor, do: "visible", else: ""}"} phx-hook="GhostCursor">
        <div class="ghost-cursor-arrow"></div>
        <div class="ghost-cursor-label"><%= if @ghost_cursor, do: @ghost_cursor.label, else: "notiert" %></div>
      </div>

      <%!-- Paper container --%>
      <main class="paper">
        <%!-- Header --%>
        <section id="section-header" data-section="header" class="cv-section">
          <h1 class="cv-name">Henry Stoll</h1>
          <p class="cv-subtitle">Data Scientist & Product Owner · Copenhagen, Denmark</p>
          <p class="cv-links">
            <span class="cv-link">henrystoll.de</span>
            <span class="cv-separator">·</span>
            <span class="cv-location">Copenhagen, DK</span>
          </p>
        </section>

        <%!-- About --%>
        <section id="section-about" data-section="about" class="cv-section">
          <h2 class="cv-heading">About</h2>
          <div id="about-content" class="cv-content" phx-hook="SectionContent" data-section-id="about">
            <p><%= @sections["about"] %></p>
          </div>
          <%= if note = @margin_notes["about"] do %>
            <.margin_note content={note.content} author={note.author} section="about" />
          <% end %>
        </section>

        <%!-- Experience --%>
        <section id="section-experience" data-section="experience" class="cv-section">
          <h2 class="cv-heading">Experience</h2>
          <div id="experience-content" class="cv-content" phx-hook="SectionContent" data-section-id="experience">
            <%= for entry <- @sections["experience"] do %>
              <div class="experience-entry">
                <div class="experience-header">
                  <span class="experience-role"><%= entry.role %></span>
                  <span class="experience-period"><%= entry.period %></span>
                </div>
                <div class="experience-company"><%= entry.company %></div>
                <p class="experience-desc"><%= entry.description %></p>
              </div>
            <% end %>
          </div>
          <%= if note = @margin_notes["experience"] do %>
            <.margin_note content={note.content} author={note.author} section="experience" />
          <% end %>
        </section>

        <%!-- Skills --%>
        <section id="section-skills" data-section="skills" class="cv-section">
          <h2 class="cv-heading">Skills</h2>
          <div id="skills-content" class="cv-content" phx-hook="SectionContent" data-section-id="skills">
            <div class="skill-tags">
              <%= for skill <- @sections["skills"] do %>
                <span class="skill-tag"><%= skill %></span>
              <% end %>
            </div>
          </div>
          <%= if note = @margin_notes["skills"] do %>
            <.margin_note content={note.content} author={note.author} section="skills" />
          <% end %>
        </section>

        <%!-- Projects --%>
        <section id="section-projects" data-section="projects" class="cv-section">
          <h2 class="cv-heading">Projects</h2>
          <div id="projects-content" class="cv-content" phx-hook="SectionContent" data-section-id="projects">
            <%= for project <- @sections["projects"] do %>
              <div class="project-entry">
                <strong class="project-name"><%= project.name %></strong>
                <span class="project-separator"> — </span>
                <span class="project-desc"><%= project.description %></span>
              </div>
            <% end %>
          </div>
          <%= if note = @margin_notes["projects"] do %>
            <.margin_note content={note.content} author={note.author} section="projects" />
          <% end %>
        </section>

        <%!-- Education --%>
        <section id="section-education" data-section="education" class="cv-section">
          <h2 class="cv-heading">Education</h2>
          <div id="education-content" class="cv-content" phx-hook="SectionContent" data-section-id="education">
            <p><%= @sections["education"] %></p>
          </div>
          <%= if note = @margin_notes["education"] do %>
            <.margin_note content={note.content} author={note.author} section="education" />
          <% end %>
        </section>

        <%!-- Footer --%>
        <footer class="cv-footer">
          <span class="footer-notiert">notiert</span>
        </footer>
      </main>
    </div>
    """
  end

  defp margin_note(assigns) do
    ~H"""
    <div class={"margin-note margin-note-#{@section} visible"} phx-hook="MarginNote" id={"margin-note-#{@section}"}>
      <div class="margin-note-author"><%= @author %></div>
      <div class="margin-note-content"><%= @content %></div>
    </div>
    """
  end
end
