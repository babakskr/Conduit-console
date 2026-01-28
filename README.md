Conduit Console ManagerConduit Console is a robust, terminal-based management dashboard for the Psiphon Conduit volunteer proxy node.This tool provides a native "Console" experience for server administrators, offering real-time status reports, action logs, and easier management of the Conduit service without needing complex manual commands.(Screenshots coming soon)✨ FeaturesNative Dashboard: A clean, text-based user interface (TUI) for monitoring your node.Action Reports: Detailed logs of node activities and interventions.Status Totals: Real-time aggregation of connection stats and bandwidth usage.Lightweight: Written purely in Shell, requiring minimal dependencies.Version Control: Built-in update checks and version tracking (currently v0.1.1).🚀 InstallationYou can install Conduit-console by cloning the repository directly to your server:# 1. Update your package list
sudo apt update && sudo apt install git -y

# 2. Clone the repository
git clone [https://github.com/babakskr/Conduit-console.git](https://github.com/babakskr/Conduit-console.git)

# 3. Enter the directory and make it executable
cd Conduit-console
chmod +x conduit-console.sh

# 4. Run the console
./conduit-console.sh
📖 UsageOnce installed, simply run the script to enter the main dashboard:./conduit-console.sh
From the menu, you can access:Start/Stop the Conduit service.View Live Logs.Check Total Status (Connections/Bandwidth).Generate Action Reports.🤝 Credits & AcknowledgementsThis project is an independent management tool built upon the shoulders of giants. Special thanks to the core developers and the open-source community:ssmirr/conduit: The core Conduit server implementation. This project wraps the functionality provided by ssmirr's incredible work.SamNet-dev/conduit-manager: Inspiration for the management structure and automation flows.⚖️ LicenseThis project is licensed under the MIT License. See the LICENSE file for details.Disclaimer: This tool is not officially affiliated with Psiphon Inc. It is a community-driven manager for the volunteer Conduit network.
