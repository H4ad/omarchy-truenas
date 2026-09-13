# TrueNAS for Omarchy

TrueNAS pool health and capacity, active alerts and system state on the Omarchy
bar, with desktop notifications when something degrades and a popout for pools,
alerts and system detail.

Run `truenasctl login` once to point the plugin at your NAS and store the API
key at mode 600. After that the bar and popout read the state the poller writes;
fuller documentation lands once the plugin is finished.

**Planned:** disks and temperatures, apps and services, replication, cloud sync
and snapshots, and shares are later milestones and are not implemented yet.
