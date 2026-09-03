#!/usr/bin/env python3
"""Render the two measured agent network flows as PNGs for the briefing document.

These are deliberately drawn from the measured facts in out/evidence, not from
an idealised architecture: snet-agent has no NAT Gateway, and the Bing call does
not originate from the customer VNet.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

CUST_FILL, CUST_EDGE = "#eaf3fb", "#0a68c1"
MS_FILL, MS_EDGE = "#f0f0f4", "#5a5a6e"
RISK_FILL, RISK_EDGE = "#fdeaea", "#c1280a"
BOX_FILL, BOX_EDGE = "#ffffff", "#33475b"


def zone(ax, x, y, w, h, label, fill, edge, ls="-"):
    ax.add_patch(Rectangle((x, y), w, h, facecolor=fill, edgecolor=edge,
                           linewidth=1.6, linestyle=ls, zorder=1))
    ax.text(x + 0.12, y + h - 0.22, label, fontsize=8.5, style="italic",
            color=edge, zorder=5, va="top")


def box(ax, x, y, w, h, text, fill=BOX_FILL, edge=BOX_EDGE, fs=8.2, bold=False):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.06",
                                facecolor=fill, edgecolor=edge, linewidth=1.3, zorder=3))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=fs,
            zorder=4, fontweight="bold" if bold else "normal", linespacing=1.35)
    return (x, y, w, h)


def arrow(ax, p1, p2, label="", color="#0a68c1", style="-", lw=1.6,
          rad=0.0, fs=7.4, offset=(0, 0.22)):
    ax.add_patch(FancyArrowPatch(p1, p2, arrowstyle="-|>", mutation_scale=13,
                                 linewidth=lw, color=color, linestyle=style,
                                 connectionstyle=f"arc3,rad={rad}", zorder=6))
    if label:
        mx, my = (p1[0] + p2[0]) / 2 + offset[0], (p1[1] + p2[1]) / 2 + offset[1]
        ax.text(mx, my, label, ha="center", va="center", fontsize=fs, color=color,
                zorder=7, bbox=dict(boxstyle="round,pad=0.18", fc="white",
                                    ec="none", alpha=0.92))


def base_axes(title, subtitle):
    fig, ax = plt.subplots(figsize=(11.6, 5.3), dpi=190)
    ax.set_xlim(0, 16); ax.set_ylim(0, 7.4); ax.axis("off")
    ax.text(0.1, 7.15, title, fontsize=13, fontweight="bold", va="top")
    ax.text(0.1, 6.72, subtitle, fontsize=8.6, color="#444", va="top", style="italic")
    return fig, ax


# --------------------------------------------------------------- Foundry IQ --
def foundry_flow(path):
    fig, ax = base_axes(
        "Flow A — Agent → Foundry IQ  (every hop private)",
        "Measured: run_Kv6htVtMAKyjgWgeS5qAaX7P completed, tool azure_ai_search, "
        "answer quoted a canary string present only in the private index.")

    zone(ax, 0.2, 0.5, 8.9, 5.7, "ST tenant — VNet 10.30.0.0/16", CUST_FILL, CUST_EDGE)
    zone(ax, 0.45, 3.55, 2.5, 2.2, "snet-app 10.30.1.0/24", "#ffffff", "#9bb8d3", ls="--")
    zone(ax, 0.42, 0.85, 2.85, 2.3, "snet-agent 10.30.3.0/24", "#dcecfa", CUST_EDGE, ls="--")
    zone(ax, 3.35, 0.85, 5.5, 4.9, "snet-pe 10.30.2.0/24", "#ffffff", "#9bb8d3", ls="--")
    zone(ax, 9.6, 0.5, 6.2, 5.7, "Microsoft-managed — Sweden Central", MS_FILL, MS_EDGE)

    app = box(ax, 0.7, 4.25, 2.0, 0.95, "Client app\n/ user")
    rt = box(ax, 0.58, 1.35, 2.15, 1.25,
             "Agent runtime\nserverless — no NIC\nlegionservicelink",
             fill="#cfe4f7", edge=CUST_EDGE, fs=7.6, bold=True)
    pef = box(ax, 3.65, 4.25, 2.4, 0.95, "PE Foundry\n10.30.2.5/.6/.7", fs=7.8)
    pes = box(ax, 3.65, 1.45, 2.4, 0.95, "PE Search\n10.30.2.10", fs=7.8)

    fdy = box(ax, 10.1, 4.25, 2.6, 0.95, "Foundry /\nAgent Service", fill="#e6ecf5", fs=7.9)
    srch = box(ax, 10.1, 2.55, 2.6, 0.95, "Azure AI Search\npublic = Disabled",
               fill="#e6ecf5", fs=7.6)
    mdl = box(ax, 10.1, 0.9, 2.6, 0.95, "gpt-4.1-mini\ndeployment", fill="#e6ecf5", fs=7.9)

    arrow(ax, (2.7, 4.72), (3.65, 4.72), "1  HTTPS, Entra ID", offset=(0.05, 0.30), fs=7.0)
    arrow(ax, (6.05, 4.72), (10.1, 4.72), "")
    arrow(ax, (11.4, 4.25), (2.7, 2.15), "2  dispatch to injected runtime",
          color="#5a5a6e", style="--", rad=-0.16, offset=(0.9, 0.95))
    arrow(ax, (2.7, 1.92), (3.65, 1.92), "3  query\nproject MI", offset=(0.05, -0.55), fs=7.0)
    arrow(ax, (6.05, 1.92), (10.1, 3.0), "", rad=0.08)
    arrow(ax, (11.4, 2.55), (11.4, 1.85), "4  shared private link", offset=(2.0, 0.0))
    arrow(ax, (12.7, 3.5), (12.7, 4.25), "5  grounded answer", rad=0.0, offset=(1.5, 0.0))

    ax.text(0.35, 0.13,
            "No public IP address appears anywhere in this path. NSG / UDR / proxy on "
            "snet-agent DO apply — proved by denying 10.30.2.10, which broke the agent.",
            fontsize=8.1, color=CUST_EDGE, style="italic")
    fig.savefig(path, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  wrote {path}")


# ------------------------------------------------------------------ Web IQ --
def web_flow(path):
    fig, ax = base_axes(
        "Flow B — Agent → Web IQ  (the Bing call never enters ST's network)",
        "Measured: run_OCfq9N0mIoyym0lyPNKNuygS completed with ALL Internet egress "
        "denied on snet-agent — so the call is made service-side by Microsoft.")

    zone(ax, 0.2, 0.5, 6.4, 5.7, "ST tenant — VNet 10.30.0.0/16", CUST_FILL, CUST_EDGE)
    zone(ax, 0.45, 0.85, 2.7, 2.5, "snet-agent  (Deny * → Internet)", "#dcecfa", CUST_EDGE, ls="--")
    zone(ax, 6.9, 0.5, 5.3, 5.7, "Microsoft-managed", MS_FILL, MS_EDGE)
    zone(ax, 12.5, 0.5, 3.3, 5.7, "Outside the Azure DPA", RISK_FILL, RISK_EDGE)

    app = box(ax, 0.7, 4.3, 2.3, 0.95, "Client app\nsnet-app")
    pef = box(ax, 3.6, 4.3, 2.6, 0.95, "PE Foundry\n10.30.2.5/.6/.7", fs=7.8)
    rt = box(ax, 0.7, 1.5, 2.2, 1.3, "Agent runtime\nInternet egress\nBLOCKED",
             fill="#cfe4f7", edge=CUST_EDGE, fs=7.6, bold=True)

    fdy = box(ax, 7.3, 4.3, 2.9, 0.95, "Foundry /\nAgent Service", fill="#e6ecf5", fs=7.9)
    bing = box(ax, 7.3, 1.9, 2.9, 1.5,
               "Grounding with Bing\niqspoc-bing\nlocation = global\nFirst Party\nConsumption Service",
               fill=RISK_FILL, edge=RISK_EDGE, fs=7.2, bold=True)
    web = box(ax, 12.9, 2.2, 2.5, 1.1, "Public web /\nBing index",
              fill=RISK_FILL, edge=RISK_EDGE, fs=8.0)

    arrow(ax, (3.0, 4.77), (3.6, 4.77), "1")
    arrow(ax, (6.2, 4.77), (7.3, 4.77), "")
    arrow(ax, (8.2, 4.3), (2.9, 2.5), "2  dispatch", color="#5a5a6e", style="--",
          rad=-0.16, offset=(0.2, 0.4))
    arrow(ax, (2.9, 2.1), (7.3, 2.9), "3  tool call stays in-service",
          color="#5a5a6e", style="--", rad=0.10, offset=(0, 0.4))
    arrow(ax, (8.75, 4.3), (8.75, 3.4), "4  SERVICE-SIDE CALL\napi.bing.microsoft.com\nAPI key — NOT from ST",
          color=RISK_EDGE, lw=2.4, offset=(2.75, 0.30), fs=7.3)
    arrow(ax, (10.2, 2.65), (12.9, 2.75), "", color=RISK_EDGE, lw=2.0)
    arrow(ax, (10.05, 3.4), (10.05, 4.3), "5  results", color=RISK_EDGE, rad=0.0, offset=(-0.75, 0.0), fs=7.3)

    ax.text(0.35, 0.13,
            "ST has NO network-layer control here: nothing to proxy, inspect or firewall. "
            "Govern by withholding the Bing connection + Azure Policy.",
            fontsize=8.1, color=RISK_EDGE, style="italic")
    fig.savefig(path, bbox_inches="tight", facecolor="white")
    plt.close(fig)
    print(f"  wrote {path}")


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp"
    foundry_flow(f"{out}/flow-foundry-iq.png")
    web_flow(f"{out}/flow-web-iq.png")
