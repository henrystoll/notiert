defmodule NotiertWeb.CvLive do
  @moduledoc """
  Main LiveView for the notiert living CV.

  Renders the CV, manages per-visitor session state, and coordinates
  the director agent loop that rewrites content in real-time.
  """
  use NotiertWeb, :live_view

  alias Notiert.Director.{Session, Phase}

  @version "0.2.0-phoenix"

  @impl true
  def mount(params, _session, socket) do
    debug? = Map.has_key?(params, "debug")

    socket =
      socket
      |> assign(
        version: @version,
        debug: debug?,
        phase: :silent,
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
        # Typing animation queue
        typing: nil,
        # Event log for reveal section
        event_log: []
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

    {:noreply, socket}
  end

  @impl true
  def handle_info({:event_log_update, event_log}, socket) do
    {:noreply, assign(socket, event_log: event_log)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp apply_director_action(%{"tool" => "rewrite_section"} = action, socket) do
    section_id = action["section_id"]
    content = action["content"]
    tone = action["tone"] || "subtle"
    typing_speed = action["typing_speed"] || "normal"

    mutations = Map.put(socket.assigns.mutations, section_id, content)

    # Auto-show cursor at the section being edited (like Google Docs)
    cursor = %{label: socket.assigns.ghost_cursor && socket.assigns.ghost_cursor.label || "notiert", target: section_id}

    socket
    |> assign(mutations: mutations, ghost_cursor: cursor)
    |> push_event("show_cursor", %{label: cursor.label, target: cursor.target})
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

  defp apply_director_action(%{"tool" => "show_cursor"} = action, socket) do
    cursor = %{label: action["label"], target: action["target"]}

    socket
    |> assign(ghost_cursor: cursor)
    |> push_event("show_cursor", %{label: cursor.label, target: cursor.target})
  end

  defp apply_director_action(%{"tool" => "hide_cursor"}, socket) do
    socket
    |> assign(ghost_cursor: nil)
    |> push_event("hide_cursor", %{})
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

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp default_sections do
    %{
      "about" =>
        "Deliver scalable AI systems where people, data, and systems meet real-world problems: moving fast, cutting through complexity, and driving impact to overcome inertia. Background spans startup-style execution, where speed and vision drive results, and enterprise-scale architecture, where scale, compliance and reusability are critical. Experienced in leading teams, managing stakeholders, and delivering end-to-end solutions in cloud-native environments.",
      "experience" => [
        %{
          role: "Senior Data Scientist",
          company: "Danske Bank, Copenhagen",
          period: "2024–Present",
          description:
            "GenAI Engineer & Architect. Design and implementation of GenAI RAG platform solutions. Driving enterprise reference architecture for scalable Agent Orchestration and Tools with A2A and MCP, balancing rapid time-to-value with long-term reliability. Advocated approach to 350 colleagues across the bank."
        },
        %{
          role: "Data Scientist",
          company: "UNHCR, Copenhagen",
          period: "2023–2024",
          description:
            "Architected and deployed cloud-native, event-driven systems for multilingual hate detection using Llama2/Mistral, capable of classifying 10,000 posts/minute. Built MLOps pipelines on AWS and GCP. Technical lead for external developer team."
        },
        %{
          role: "CTO",
          company: "Stealth Startup, Copenhagen",
          period: "2023",
          description:
            "Built an integrated employee-manager chatbot and coach. Designed and delivered cloud-native SaaS from whiteboard to pilot with 40 users, leveraging LLM orchestration, RAG, FastAPI and Svelte."
        },
        %{
          role: "Technology Consultant",
          company: "UNICEF, Copenhagen",
          period: "2021–2023",
          description:
            "Technical lead for supply visibility solution in global NGO logistics. Led cross-border implementation in 10+ countries. Managed a team of 5, designed scalable mobile solutions for 9,000+ NGO partners. Built with Nest, React and Databricks on Azure."
        },
        %{
          role: "Business Informatics Student",
          company: "SAP, Walldorf & Palo Alto",
          period: "2016–2019",
          description:
            "Technology and strategy consultant across Finance, Insurance, Automotive, Manufacturing and Consumer Goods in Germany and the US. Focus on AI and ERP system integration. Part-time assistance role to a Supervisory Board member."
        }
      ],
      "skills" => [
        "Python/FastAPI",
        "LangChain/RAG",
        "Agent Orchestration",
        "AWS",
        "GCP",
        "Azure",
        "Terraform/CDK",
        "Docker",
        "Kubernetes",
        "MLflow",
        "TensorFlow/PyTorch",
        "PostgreSQL",
        "Node/Nest",
        "React/Svelte",
        "Elixir",
        "German (native)",
        "English (proficient)"
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
            "This website. A living CV that watches its visitors and rewrites itself in real-time using an LLM director agent."
        }
      ],
      "education" =>
        "M.Sc. Data Science & Business Administration — Copenhagen Business School (top 5%). B.Sc. Business Informatics — DHBW (top 10%). Additional coursework: Big Data Management (ITU), Advanced NLP (University of Copenhagen)."
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="notiert-app" phx-hook="Notiert" data-debug={to_string(@debug)}>
      <%!-- Version label --%>
      <div class="version-label">notiert v<%= @version %></div>

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
          <p class="cv-subtitle">GenAI Engineer @Danske Bank | AI Architect</p>
          <p class="cv-links">
            <span class="cv-link">henrystoll.de</span>
            <span class="cv-separator">·</span>
            <span class="cv-location">Copenhagen, Denmark</span>
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

        <%!-- Reveal: interaction log --%>
        <%= if @phase in [:overt, :climax] and @event_log != [] do %>
          <section id="section-reveal" data-section="reveal" class="cv-section reveal-section">
            <h2 class="cv-heading">Session Log</h2>
            <pre class="reveal-log"><%= Notiert.Director.Agent.format_notebook(@event_log) %></pre>
          </section>
        <% end %>

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
