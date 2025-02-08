# Azure Arc WS Management License Activation Script

This PowerShell script automates the process of checking and enabling Windows Server licenses for Azure Arc-enabled machines.

Upon attestation, customers receive access to the following at no additional cost beyond networking, storage, and log ingestion:

  - Azure Update Manager
  - Azure Change Tracking and Inventory
  - Azure Machine Configuration
  - Windows Admin Center in Azure for Arc
  - Remote Support
  - Network HUD
  - Best Practices Assessment
  - Azure Site Recovery Configuration

Azure Change Tracking and Inventory and Best Practices Assessment require a Log Analytics workspace that may incur data ingestion costs. While the configuration of Azure Site Recovery is included as a benefit, customers incur costs for the Azure Site Recovery service itself, including for any storage, compute, and networking associated with the service.

## 🚀 Features

- Retrieves a list of Azure Arc machines in a given **subscription and resource group**.
- Checks the **Windows Server license activation status**.
- Exports the results to a CSV file (`AzureArc_LicenseStatus.csv`).
- Enables the **Software Assurance license** for machines where it is not already activated.
- Updates the CSV with the operation results.

## 📌 Prerequisites

1. Install **Azure PowerShell**:
   ```powershell
   Install-Module -Name Az -AllowClobber -Force
   ```
2. Ensure you have the necessary permissions to manage Azure Arc machines.
3. Authenticate to Azure before running the script.

## 📌 Requirementes for Azure Arc WS Management 

  - Agent Version: Connected Machine Agent version 1.47 or higher is required.
  
  - Operating Systems: The Azure Arc-enabled server’s Operating Systems must be Windows Server 2012 or higher with both Standard/Datacenter editions supported.
  
  - Networking: Connectivity methods supported include Public Endpoint, Proxy, Azure Arc Gateway, and Private Endpoint. No additional endpoints need to be allowed.
  
  - Licensing: The Azure Arc-enabled server must be officially licensed through a valid licensing channel. Unlicensed servers aren't eligible for these benefits. Azure Arc-enabled servers enrolled in Windows Server pay-as-you-go are automatically activated for these benefits.
  
  - Connectivity: The Azure Arc-enabled server must be Connected for enrollment. Disconnected and expired servers aren't eligible. Usage of the included benefits requires connectivity.
  
  - Regions: Activation is available in all regions where Azure Arc-enabled servers has regional availability except for US Gov Virginia, US Gov Arizona, China North 2, China North 3, and China East 2.
  
  - Environments: Supported environments include Hyper-V, VMware, SCVMM, Stack HCI, AVS, and bare-metal where servers are connected to Azure Arc.
  
  - Modes: Customers can use Monitor mode and extension allowlists or blocklists with their attestation to Azure Arc-enabled servers

## 📄 How to Use

### 1️⃣ Clone the Repository

```sh
git clone https://github.com/mustafakaya/azure-arc-license-activation.git
cd azure-arc-tools
```

### 2️⃣ Run the Script

```powershell
.\AzureArc-ActivateWSMLicense.ps1 -SubscriptionId "your-subscription-id" -ResourceGroupName "your-resource-group" -CsvPath "full-path-of-csv"
```

### 3️⃣ Understanding the Output

After execution, a CSV file (`AzureArc_LicenseStatus.csv`) is generated with the following columns:

| MachineName | LicenseStatus | Operation                       |
| ----------- | ------------- | ------------------------------- |
| ArcMachine1 | Enabled       | Already enabled                 |
| ArcMachine2 | Disabled      | License activated               |
| ArcMachine3 | Unknown       | Error occurred: [error details] |

## 🔧 Parameters Explained

| Parameter            | Description                                      |
| -------------------- | ------------------------------------------------ |
| `-SubscriptionId`    | Azure Subscription ID                            |
| `-ResourceGroupName` | Azure Resource Group containing Arc machines     |
| `-CsvPath`           | Full path of CSV file                            |

---

**Contributions Welcome!** 🤝 Feel free to fork, improve, and submit a PR!

Reference: https://learn.microsoft.com/en-us/azure/azure-arc/servers/windows-server-management-overview?tabs=portal
