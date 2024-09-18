
terraform {
  required_version = ">= 1.5.0, < 2.0.0"
  backend "gcs" {
    bucket = "dgc-sandbox-hrialan-terraform"
    prefix = "tailscale/"
  }
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0, <6.0.0"
    }
  }
}

provider "google" {
  project = var.project
}

variable "project" {
  description = "The GCP project ID"
  type        = string
}

variable "auth_key" {
  description = "Tailscale auth key"
  type        = string
  sensitive   = true
}

variable "nextdns_profile_id" {
  description = "NextDNS profile id"
  type        = string
}

variable "vm_configs" {
  description = "Configuration for VMs in different countries"
  type = map(object({
    region       = string
    zone         = string
    machine_type = string
    cidr         = string
  }))
  default = {
    france = {
      region       = "europe-west9"
      zone         = "europe-west9-a"
      machine_type = "e2-micro"
      cidr         = "10.0.1.0/24"
    }
    switzerland = {
      region       = "europe-west6"
      zone         = "europe-west6-a"
      machine_type = "e2-micro"
      cidr         = "10.0.2.0/24"
    }
  }
}

# Create VPC network
resource "google_compute_network" "vpc_network" {
  name                    = "tailscale-network"
  auto_create_subnetworks = false
}

# Create subnetworks for each region
resource "google_compute_subnetwork" "subnetwork" {
  for_each      = var.vm_configs
  name          = "tailscale-subnetwork-${each.key}"
  ip_cidr_range = each.value.cidr
  network       = google_compute_network.vpc_network.self_link
  region        = each.value.region
}

# Create a dedicated service account for Tailscale VMs
resource "google_service_account" "tailscale_service_account" {
  account_id   = "tailscale-vm-sa"
  display_name = "Tailscale VM Service Account"
}

# Create Resource Policies for scheduling
resource "google_compute_resource_policy" "instance_schedule" {
  for_each = var.vm_configs
  name        = "tailscale-instance-schedule-${each.key}"
  region      = each.value.region
  description = "Start and stop VMs daily for ${each.key}"

  instance_schedule_policy {
    vm_start_schedule {
      schedule = "0 6 * * *"
    }
    vm_stop_schedule {
      schedule = "0 23 * * *"
    }
    time_zone = "Europe/Paris"
  }
}

# Create compute instances
resource "google_compute_instance" "tailscale_instance" {
  for_each       = var.vm_configs
  name           = "tailscale-vm-${each.key}"
  machine_type   = each.value.machine_type
  zone           = each.value.zone
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.self_link
    subnetwork = google_compute_subnetwork.subnetwork[each.key].self_link

    access_config {
      network_tier = "STANDARD"
    }
  }

  tags = ["tailscale"]

  service_account {
    email  = google_service_account.tailscale_service_account.email
    scopes = ["https://www.googleapis.com/auth/compute.readonly"]
  }

  metadata = {
    block-project-ssh-keys = true
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    LOGFILE="/var/log/startup-script.log"
    exec > >(tee -a $LOGFILE) 2>&1

    # Update package list and install necessary packages
    apt-get update
    apt-get install -y curl apt-transport-https
    if [ $? -ne 0 ]; then
      echo "Failed to install curl or apt-transport-https" >&2
      exit 1
    fi

    # Install Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh
    if [ $? -ne 0 ]; then
      echo "Failed to install Tailscale" >&2
      exit 1
    fi

    # Install and activate NextDNS
    wget -qO /usr/share/keyrings/nextdns.gpg https://repo.nextdns.io/nextdns.gpg
    if [ $? -ne 0 ]; then
      echo "Failed to download NextDNS GPG key" >&2
      exit 1
    fi

    echo "deb [signed-by=/usr/share/keyrings/nextdns.gpg] https://repo.nextdns.io/deb stable main" | tee /etc/apt/sources.list.d/nextdns.list
    apt-get update
    apt-get install -y nextdns
    if [ $? -ne 0 ]; then
      echo "Failed to install NextDNS" >&2
      exit 1
    fi

    nextdns install \
      -profile ${var.nextdns_profile_id} \
      -auto-activate

    # Enable port forwarding
    echo 'net.ipv4.ip_forward = 1' | tee -a /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' | tee -a /etc/sysctl.conf
    sysctl -p /etc/sysctl.conf

    # Disable SSH for security
    systemctl stop ssh
    systemctl disable ssh

    # Authenticate and set up as exit node with tag
    tailscale up --authkey=${var.auth_key} --advertise-exit-node --hostname=gce-${each.key} --advertise-tags=tag:gce-exit-node --accept-routes=false --accept-dns=false
    if [ $? -ne 0 ]; then
      echo "Failed to set up Tailscale" >&2
      exit 1
    fi

    # Enable automatic updates
    apt-get install -y unattended-upgrades
    dpkg-reconfigure --priority=low unattended-upgrades

    # Mount /tmp, /var/log, and /var/tmp as tmpfs
    echo 'tmpfs /tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777,size=512M 0 0' | tee -a /etc/fstab
    echo 'tmpfs /var/log tmpfs defaults,noatime,nosuid,nodev,mode=0755,size=512M 0 0' | tee -a /etc/fstab
    echo 'tmpfs /var/tmp tmpfs defaults,noatime,nosuid,nodev,mode=1777,size=512M 0 0' | tee -a /etc/fstab
    
    # Ensure directories are empty before mounting
    rm -rf /tmp/*
    rm -rf /var/log/*
    rm -rf /var/tmp/*

    mount /tmp
    mount /var/log
    mount /var/tmp

    # Configure local firewall
    apt-get install -y ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 41641/udp
    ufw enable
  EOT

  resource_policies = [google_compute_resource_policy.instance_schedule[each.key].id]
}

# Create firewall rule for Tailscale (IPv4)
resource "google_compute_firewall" "tailscale_firewall_ipv4" {
  name    = "allow-tailscale-ipv4"
  network = google_compute_network.vpc_network.self_link

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["tailscale"]
}

# Create firewall rule for Tailscale (IPv6)
resource "google_compute_firewall" "tailscale_firewall_ipv6" {
  name    = "allow-tailscale-ipv6"
  network = google_compute_network.vpc_network.self_link

  allow {
    protocol = "udp"
    ports    = ["41641"]
  }

  source_ranges = ["::/0"]
  target_tags   = ["tailscale"]
}

# Create firewall rule for SSH
# Comment if not necessary
# resource "google_compute_firewall" "ssh_firewall" {
#   name    = "allow-ssh"
#   network = google_compute_network.vpc_network.self_link

#   allow {
#     protocol = "tcp"
#     ports    = ["22"]
#   }

#   source_ranges = ["0.0.0.0/0"]
#   target_tags   = ["tailscale"]
# }
