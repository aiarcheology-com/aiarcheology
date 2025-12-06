# 📱 MLBrowser iOS App

Welcome to the MLBrowser project repository.

## 🛠️ Initial Project Setup

Before opening the Xcode project or starting development, you **must** run the project setup tool.

### Prerequisites

* **Xcode:** Latest stable version (includes Swift and Swift Package Manager).

### Setup Instructions

1.  **Clone the Repository:**
    ```bash
    git clone [your_repo_url]
    cd aiarcheology
    ```

2.  **Run the Setup Tool:**
    Use Swift Package Manager to build and execute the `ProjectTool` with the `setup` command, specifying the location of the package manifest.

    ```bash
    swift run --package-path Tools ProjectTool setup
    ```

    * *Note: The first time this runs, SwiftPM will resolve dependencies and build the tool, which may take a few seconds.*

3.  **Open the Project:**
    After the setup script successfully completes, you can open your Xcode project/workspace.
    
    ```bash
    open AI\ Archeology.xcodeproj
    ```
