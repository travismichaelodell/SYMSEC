#!/bin/bash

# Shell Installer Script for Tailscale, Tor, I2P Integration with Randomization and Gemini Auto-Rules

set -e

# Constants
STARTUP_SCRIPT="/etc/systemd/system/secure-stack.service"
CONFIGURATOR_SCRIPT="/usr/local/bin/reconfigure_secure_stack.sh"
FIREWALL_GUI_SCRIPT="/usr/local/bin/firewall_gui.py"
PYTHON_TUI_SCRIPT="/usr/local/bin/secure_stack_tui.py"
CONFIG_FILE="$HOME/.securestacksetup_config.json"

# Function to check for root permissions
require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root or using sudo."
    exit 1
  fi
}

# Function to fetch Gemini API key and URL using the Python TUI
get_gemini_config() {
    if [ -f "$CONFIG_FILE" ]; then
        GEMINI_API_KEY=$(jq -r .gemini_api_key "$CONFIG_FILE")
        GEMINI_API_URL=$(jq -r .gemini_api_url "$CONFIG_FILE")
        if [ -n "$GEMINI_API_KEY" ] && [ -n "$GEMINI_API_URL" ]; then
            echo "Gemini API key and URL found in config file."
            return 0
        fi
    fi

    echo "Gemini API key or URL not found. Launching configuration TUI..."
    if ! "$PYTHON_TUI_SCRIPT"; then
        echo "Error: TUI script not found or failed to run."
        return 1
    fi

    if [ -f "$CONFIG_FILE" ]; then
        GEMINI_API_KEY=$(jq -r .gemini_api_key "$CONFIG_FILE")
        GEMINI_API_URL=$(jq -r .gemini_api_url "$CONFIG_FILE")
        if [ -n "$GEMINI_API_KEY" ] && [ -n "$GEMINI_API_URL" ]; then
            echo "Gemini API key and URL obtained from TUI."
            return 0
        fi
    fi

    echo "Error: Could not obtain Gemini API key and URL."
    return 1
}

# Error handling function with Gemini integration
handle_error() {
  local message="$1"
  local cmd="$2"
  echo "Error: $message" >&2

  if [ -n "$GEMINI_API_KEY" ] && [ -n "$GEMINI_API_URL" ]; then
    echo "Attempting to resolve the error using Gemini..."

    PROMPT="An error occurred in a bash script: '$message'. The command that caused the error was: '$cmd'. Provide a concise solution or alternative command to fix the error."
    FIX=$(curl -s -H "Authorization: Bearer $GEMINI_API_KEY" -d "{\"prompt\": \"$PROMPT\"}" "$GEMINI_API_URL" | jq -r .response)

    if [ -n "$FIX" ]; then
      echo "Suggested fix from Gemini: $FIX"
      echo "Applying suggested fix..."
      eval "$FIX"
      if [ $? -eq 0 ]; then
        echo "Gemini's fix was applied successfully."
        return 0  # Indicate success to potentially continue
      else
        echo "Gemini's fix failed."
      fi
    else
      echo "Gemini could not provide a fix."
    fi
  fi

  echo "Error could not be resolved automatically."
  cleanup
  exit 1
}

# Cleanup function
cleanup() {
  echo "Performing cleanup..."
  if [ -n "$STARTUP_SCRIPT" ]; then
      systemctl disable secure-stack.service 2>/dev/null || true
      systemctl stop secure-stack.service 2>/dev/null || true
  fi
   if [ -f "$FIREWALL_GUI_SCRIPT" ]; then
    rm "$FIREWALL_GUI_SCRIPT"
   fi
  if [ -f "$PYTHON_TUI_SCRIPT" ]; then
    rm "$PYTHON_TUI_SCRIPT"
  fi
  if [ -f "/tmp/ufw_rules.txt" ]; then
      rm /tmp/ufw_rules.txt
  fi
   if [ -f "$CONFIGURATOR_SCRIPT" ]; then
     rm "$CONFIGURATOR_SCRIPT"
   fi
  echo "Cleanup completed."
}

# Function to check for and install locate, then populate variables
setup_locate_and_paths() {
    if command -v locate &>/dev/null; then
        echo "Locate command found."
    else
        echo "Locate command not found, attempting to install."
        apt-get update &>/dev/null
        if ! apt-get install -y mlocate &>/dev/null; then
            echo "Failed to install mlocate."
            echo "Please ensure 'mlocate' package is installed and try again."
            echo "Falling back to standard paths..."
        
             TAILSCALE_CONFIG_DIR="/etc/tailscale"
             TOR_CONFIG_DIR="/etc/tor"
             I2P_CONFIG_DIR="/etc/i2p"
             UFW_RULES_FILE="/etc/ufw/user.rules"
            return
        else
            echo "mlocate installed successfully, updating database..."
            updatedb &>/dev/null
        fi
    fi
    
    TAILSCALE_CONFIG_DIR=$(locate -b "/tailscale" | head -n 1)
    TOR_CONFIG_DIR=$(locate -b "/etc/tor" | head -n 1)
    I2P_CONFIG_DIR=$(locate -b "/etc/i2p" | head -n 1)
    UFW_RULES_FILE=$(locate -b "/etc/ufw/user.rules" | head -n 1)

    if [ -z "$TAILSCALE_CONFIG_DIR" ]; then
      TAILSCALE_CONFIG_DIR="/etc/tailscale"
      echo "Tailscale config directory not found with locate. Falling back to /etc/tailscale"
    fi
        if [ -z "$TOR_CONFIG_DIR" ]; then
      TOR_CONFIG_DIR="/etc/tor"
     echo "Tor config directory not found with locate. Falling back to /etc/tor"
    fi
        if [ -z "$I2P_CONFIG_DIR" ]; then
       I2P_CONFIG_DIR="/etc/i2p"
       echo "I2P config directory not found with locate. Falling back to /etc/i2p"
    fi
        if [ -z "$UFW_RULES_FILE" ]; then
      UFW_RULES_FILE="/etc/ufw/user.rules"
      echo "UFW config file not found with locate. Falling back to /etc/ufw/user.rules"
    fi

  echo "Path Configuration Complete."
}

# Function to install python dependencies
install_python_dependencies(){
  if ! pip3 install typer rich &>/dev/null; then
    echo "Failed to install python TUI dependencies."
     echo "Please ensure 'python3-pip' and 'python3-venv' are installed and try again."
     handle_error "Python dependencies not installed." "pip3 install typer rich"
  fi
    echo "Python TUI dependencies installed successfully."
}

# Function to install the python TUI script
install_python_tui(){
  echo "Installing python TUI..."
  cat <<EOF > "$PYTHON_TUI_SCRIPT"
#!/usr/bin/env python3

import typer
from rich.console import Console
from rich.prompt import Prompt, Confirm
from rich.panel import Panel
from rich.text import Text
import os
import json

APP_NAME = "SecureStackSetup"
CONFIG_FILE = os.path.expanduser(f"~/.{APP_NAME.lower()}_config.json")

def load_config():
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, "r") as f:
            return json.load(f)
    return {}

def save_config(config):
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=4)

def initialize_config(console: Console):
    config = load_config()
    if not config.get("gemini_api_key"):
        console.print(
            Panel(
                Text(
                    "Welcome to SecureStackSetup! Before we begin, we need your Gemini API key.",
                    style="bold",
                )
            )
        )
        while True:
            gemini_key = Prompt.ask(
                "[bold yellow]Enter your Gemini API key[/bold yellow]",
                password=True,
            )
            if not gemini_key:
                console.print("[bold red]Gemini API key cannot be empty.[/bold red]")
                continue
            break
        config["gemini_api_key"] = gemini_key
        while True:
           gemini_url = Prompt.ask(
                "[bold yellow]Enter your Gemini API URL[/bold yellow]",
            )
           if not gemini_url:
                console.print("[bold red]Gemini API URL cannot be empty.[/bold red]")
                continue
           break
        config["gemini_api_url"] = gemini_url
        save_config(config)
        console.print(
            "[bold green]Gemini API key and URL saved. Proceeding with setup.[/bold green]\n"
        )
    else:
        console.print("[bold green]Gemini API key and URL found in config[/bold green]")
    return config

app = typer.Typer()
console = Console()

@app.command()
def main():
    config = initialize_config(console)
    gemini_api_key = config["gemini_api_key"]
    gemini_api_url = config["gemini_api_url"]
    console.print(
        Panel(
            Text(
                f"Gemini API Key: [bold blue]{gemini_api_key[:4]}...[/bold blue] \n Gemini API URL: [bold blue]{gemini_api_url}[/bold blue] \n Setup can continue now.",
                style="italic",
            )
        )
    )

    if Confirm.ask(
        "[bold cyan]Do you wish to proceed with the system setup[/bold cyan]?"
    ):
        console.print(
            "[bold green]Proceeding with system setup... (Your code execution here)[/bold green]"
        )
        # Add your main script execution logic here using config
        # Example: print(f"Using gemini key: {gemini_api_key}")
    else:
        console.print("[bold yellow]Setup aborted.[/bold yellow]")

if __name__ == "__main__":
    app()
EOF
  chmod +x "$PYTHON_TUI_SCRIPT"
  if [ ! -f "$PYTHON_TUI_SCRIPT" ]; then
      handle_error "Failed to create Python TUI script." "install_python_tui"
  fi
  echo "Python TUI script installed successfully at $PYTHON_TUI_SCRIPT."
}

# Update and install dependencies
install_dependencies() {
  echo "Updating package list and installing dependencies..."
  if ! apt-get update -y &>/dev/null; then
      handle_error "Failed to update package list." "apt-get update -y"
  fi

  if ! apt-get upgrade -y &>/dev/null; then
    handle_error "Failed to upgrade packages." "apt-get upgrade -y"
  fi

  if ! apt-get install -y tailscale tor i2p i2p-router ufw python3 python3-pip &>/dev/null; then
    echo "Failed to install system dependencies."
    echo "Please check that 'tailscale' 'tor' 'i2p' 'i2p-router' 'ufw' 'python3' and 'python3-pip' are correctly installed and try again"
    handle_error "Failed to install dependencies." "apt-get install -y tailscale tor i2p i2p-router ufw python3 python3-pip"
  fi
  echo "Dependencies installed successfully."
}

# Configure Tailscale ACL with Randomization
configure_tailscale_acl() {
  echo "Configuring Tailscale ACL with randomized ports..."
  if [ -z "$TAILSCALE_CONFIG_DIR" ]; then
    handle_error "Tailscale configuration directory not found." "configure_tailscale_acl"
  fi
  mkdir -p "$TAILSCALE_CONFIG_DIR"
  RANDOM_PORT_1=$((1024 + RANDOM % 64512))
  RANDOM_PORT_2=$((1024 + RANDOM % 64512))
  cat <<EOL > "$TAILSCALE_CONFIG_DIR/acl.json"
{
  "tagOwners": {
    "tag:tor-i2p": ["*"]
  },
  "acl": [
    {"action": "accept", "users": ["*"], "ports": ["$RANDOM_PORT_1", "$RANDOM_PORT_2"]},
    {"action": "accept", "users": ["*"], "ports": ["7654", "4444", "2827"]}
  ]
}
EOL
  if [ ! -f "$TAILSCALE_CONFIG_DIR/acl.json" ]; then
    handle_error "Tailscale ACL configuration failed to create." "configure_tailscale_acl"
  fi
  echo "Tailscale ACL configured: $TAILSCALE_CONFIG_DIR/acl.json"
}

# Configure Tor
configure_tor() {
    echo "Configuring Tor..."
    if [ -z "$TOR_CONFIG_DIR" ]; then
        handle_error "Tor configuration directory not found." "configure_tor"
    fi
  RANDOM_HIDDEN_PORT=$((1024 + RANDOM % 64512))
    if [ ! -d /var/lib/tor/hidden_service ]; then
        mkdir -p /var/lib/tor/hidden_service
    fi
    chown -R debian-tor:debian-tor /var/lib/tor/hidden_service
  cat <<EOL >> "$TOR_CONFIG_DIR/torrc"
Log notice file /var/log/tor/notices.log
ControlPort 9051
CookieAuthentication 1
HiddenServiceDir /var/lib/tor/hidden_service/
HiddenServicePort 80 127.0.0.1:$RANDOM_HIDDEN_PORT
EOL
    if ! systemctl restart tor &>/dev/null; then
       handle_error "Failed to restart Tor." "systemctl restart tor"
    fi
  echo "Tor configured with hidden service port: $RANDOM_HIDDEN_PORT"
}

# Configure I2P
configure_i2p() {
    echo "Configuring I2P..."
    if [ -z "$I2P_CONFIG_DIR" ]; then
        handle_error "I2P configuration directory not found." "configure_i2p"
    fi
  mkdir -p "$I2P_CONFIG_DIR"
  RANDOM_I2P_PORT=$((1024 + RANDOM % 64512))
  echo "router.consolePort=7657" > "$I2P_CONFIG_DIR/i2p.config"
  echo "router.myExternalPort=$RANDOM_I2P_PORT" >> "$I2P_CONFIG_DIR/i2p.config"

  if ! systemctl enable i2p-router &>/dev/null; then
       handle_error "Failed to enable i2p-router." "systemctl enable i2p-router"
  fi
  if ! systemctl start i2p-router &>/dev/null; then
        handle_error "Failed to start i2p-router." "systemctl start i2p-router"
    fi
  echo "I2P configured with external port: $RANDOM_I2P_PORT"
}

# Configure UFW Firewall with Gemini Rule Integration
configure_ufw() {
  echo "Configuring UFW and fetching rules from Gemini..."
  if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    handle_error "Gemini API config not found. Please run python script first." "configure_ufw"
  fi
  GEMINI_API_KEY=$(jq -r .gemini_api_key "$CONFIG_FILE")
    if [ -z "$GEMINI_API_KEY" ]; then
       handle_error "Failed to extract gemini key from config" "configure_ufw"
    fi
   GEMINI_API_URL=$(jq -r .gemini_api_url "$CONFIG_FILE")
    if [ -z "$GEMINI_API_URL" ]; then
       handle_error "Failed to extract gemini URL from config" "configure_ufw"
   fi
  if ! ufw --force reset &>/dev/null; then
      handle_error "Failed to reset UFW." "ufw --force reset"
  fi
  if ! ufw default deny incoming &>/dev/null; then
      handle_error "Failed to set default deny incoming rule." "ufw default deny incoming"
  fi
  if ! ufw default allow outgoing &>/dev/null; then
      handle_error "Failed to set default allow outgoing rule." "ufw default allow outgoing"
  fi
    # Generate UFW rules using the generative API
  PROMPT="Generate UFW firewall rules for common server services including ssh, http and https"
  GENERATED_RULES=$(curl -s -H "Authorization: Bearer $GEMINI_API_KEY" -d "{\"prompt\": \"$PROMPT\"}" "$GEMINI_API_URL" | jq -r .response)

   if [ -z "$GENERATED_RULES" ]; then
       echo "Warning: Could not get firewall rules from Gemini API. Applying default ufw rules."
        if ! ufw allow ssh &>/dev/null; then
             echo "Warning: Failed to allow ssh."
        fi
        if ! ufw allow http &>/dev/null; then
             echo "Warning: Failed to allow http."
        fi
        if ! ufw allow https &>/dev/null; then
             echo "Warning: Failed to allow https."
        fi

    else
       echo "$GENERATED_RULES" | while IFS= read -r RULE; do
          if ! ufw allow "$RULE" &>/dev/null; then
              echo "Warning: Failed to add UFW rule: $RULE"
          fi
       done
    fi
  if ! ufw enable &>/dev/null; then
    handle_error "Failed to enable UFW." "ufw enable"
  fi
  echo "UFW configured."
}

# Start Tailscale
start_tailscale() {
  echo "Starting and configuring Tailscale..."
  if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
      handle_error "Gemini API config not found. Please run python script first." "start_tailscale"
  fi
  TAILSCALE_AUTH_KEY=$(jq -r .tailscale_auth_key "$CONFIG_FILE")
  if [ -z "$TAILSCALE_AUTH_KEY" ]; then
      echo "Tailscale Auth Key not found in config, proceeding without it."
      tailscale up --advertise-routes=10.0.0.0/24
  else
    tailscale up --advertise-routes=10.0.0.0/24 --authkey="$TAILSCALE_AUTH_KEY"
  fi
  if [ "$?" -ne 0 ]; then
    handle_error "Failed to start or configure Tailscale." "start_tailscale"
  fi
  echo "Tailscale started."
}

# Install PySide6 GUI for Reclassification
install_gui() {
  echo "Setting up PySide6 GUI for firewall rule reclassification..."
  if ! pip3 install PySide6 &>/dev/null; then
    handle_error "Failed to install PySide6." "install_gui"
  fi
  cat <<EOF > "$FIREWALL_GUI_SCRIPT"
#!/usr/bin/env python3
from PySide6.QtWidgets import QApplication, QMainWindow, QVBoxLayout, QPushButton, QTextEdit, QWidget, QMessageBox
import subprocess
import os

class FirewallGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Firewall Rule Reclassification")

        self.text_area = QTextEdit()
        self.update_button = QPushButton("Update Rules")
        self.update_button.clicked.connect(self.update_rules)

        layout = QVBoxLayout()
        layout.addWidget(self.text_area)
        layout.addWidget(self.update_button)

        container = QWidget()
        container.setLayout(layout)
        self.setCentralWidget(container)

        self.load_rules()

    def load_rules(self):
        try:
            rules = subprocess.check_output(["ufw", "status"], text=True).decode("utf-8")
            self.text_area.setText(rules)
        except subprocess.CalledProcessError as e:
           QMessageBox.critical(self,"Error", f"Error loading rules: {e}")
           return

    def update_rules(self):
        new_rules = self.text_area.toPlainText()
        try:
            subprocess.run(["ufw", "reset"], check=True)
            for rule in new_rules.splitlines():
                if rule.strip():
                   subprocess.run(["ufw", "allow", rule], check=True)
            subprocess.run(["ufw", "enable"], check=True)
            self.load_rules()
            QMessageBox.information(self,"Success", "Firewall rules updated successfully")
        except subprocess.CalledProcessError as e:
           QMessageBox.critical(self,"Error", f"Error updating rules: {e}")

if __name__ == "__main__":
    app = QApplication([])
    gui = FirewallGUI()
    gui.show()
    app.exec()
EOF

  chmod +x "$FIREWALL_GUI_SCRIPT"
  if [ ! -f "$FIREWALL_GUI_SCRIPT" ]; then
      handle_error "Failed to create Firewall GUI script." "install_gui"
  fi
  echo "GUI installed at $FIREWALL_GUI_SCRIPT"
}

# Create Startup Script
create_startup_script() {
  echo "Creating startup script..."
  cat <<EOL > "$STARTUP_SCRIPT"
[Unit]
Description=Secure Stack Auto-Start
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash $CONFIGURATOR_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL
  chmod 644 "$STARTUP_SCRIPT"
  if ! systemctl enable secure-stack.service &>/dev/null; then
    handle_error "Failed to enable secure stack service" "create_startup_script"
  fi
  echo "Startup script created and enabled."
}

# Create Configurator Script
create_configurator_script() {
  echo "Creating configurator script..."
  cat <<EOL > "$CONFIGURATOR_SCRIPT"
#!/bin/bash
set -e
configure_tailscale_acl
configure_tor
configure_i2p
configure_ufw
start_tailscale
EOL
  chmod +x "$CONFIGURATOR_SCRIPT"
   if [ ! -f "$CONFIGURATOR_SCRIPT" ]; then
       handle_error "Failed to create configurator script." "create_configurator_script"
    fi
  echo "Configurator script created at $CONFIGURATOR_SCRIPT"
}

# Main installation function
main() {
  require_root
  if ! get_gemini_config; then
      echo "Failed to obtain Gemini API configuration. Exiting."
      exit 1
  fi
  setup_locate_and_paths
  install_python_dependencies
  install_python_tui

  install_dependencies
  configure_tailscale_acl
  configure_tor
  configure_i2p
  configure_ufw
  install_gui
  create_configurator_script
  create_startup_script
  start_tailscale
  echo "Installation and configuration completed successfully!"
}

main
