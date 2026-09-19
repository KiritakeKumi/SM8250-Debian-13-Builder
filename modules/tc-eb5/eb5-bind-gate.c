// SPDX-License-Identifier: GPL-2.0-only
/* Hold only the two EB5 RTL8168 probes until the native PCIe host is bound. */
#include <linux/async.h>
#include <linux/device.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/workqueue.h>

#include "eb5-bind-gate.h"

#define EB5_GATE_NAME "tc-eb5-net-ready"
#define EB5_GATE_TIMEOUT_MS 60000

struct eb5_bind_gate {
	struct device *owner;
	struct platform_device *supplier;
	struct notifier_block notifier;
	struct delayed_work work;
	unsigned long deadline;
	unsigned long seen;
	bool ready;
};

static int eb5_nic_index(const struct pci_dev *pdev)
{
	if (pci_domain_nr(pdev->bus) != 1 || pdev->vendor != PCI_VENDOR_ID_REALTEK ||
	    pdev->device != 0x8168 || pdev->devfn != PCI_DEVFN(0, 0))
		return -1;
	if (pdev->bus->number == 4)
		return 0;
	if (pdev->bus->number == 5)
		return 1;
	return -1;
}

static int eb5_pci_notify(struct notifier_block *nb, unsigned long action, void *data)
{
	struct eb5_bind_gate *gate = container_of(nb, struct eb5_bind_gate, notifier);
	struct device *dev = data;
	struct pci_dev *pdev = to_pci_dev(dev);
	int index = eb5_nic_index(pdev);

	if (index < 0)
		return NOTIFY_DONE;
	if (action == BUS_NOTIFY_ADD_DEVICE) {
		/* Preserve explicit driver assignment; never write driver_override. */
		if (device_has_driver_override(dev)) {
			dev_info(gate->owner, "NETGATE: %s has an override; left untouched\n",
				 dev_name(dev));
			return NOTIFY_DONE;
		}
		/* Core-owned managed link: removal of either device cleans it up. */
		if (!device_link_add(dev, &gate->supplier->dev, DL_FLAG_AUTOPROBE_CONSUMER)) {
			dev_err(gate->owner, "NETGATE: cannot gate %s; native path unchanged\n",
				dev_name(dev));
			return NOTIFY_DONE;
		}
		set_bit(index, &gate->seen);
		dev_info(gate->owner, "NETGATE: holding %s until native host completion\n",
			 dev_name(dev));
	} else if (action == BUS_NOTIFY_BOUND_DRIVER && test_bit(index, &gate->seen)) {
		dev_info(gate->owner, "NETGATE: bound %s driver=%s async=%d\n",
			 dev_name(dev), dev->driver->name, current_is_async());
	}
	return NOTIFY_OK;
}

static bool eb5_host_is_bound(void)
{
	struct device *host;
	bool bound = false;

	host = bus_find_device_by_name(&platform_bus_type, NULL, "1c08000.pcie");
	if (!host)
		return false;
	if (device_trylock(host)) {
		bound = host->driver && !strcmp(host->driver->name, "qcom-pcie") &&
			device_is_bound(host);
		device_unlock(host);
	}
	put_device(host);
	return bound;
}

static void eb5_drop_supplier(struct eb5_bind_gate *gate)
{
	bus_unregister_notifier(&pci_bus_type, &gate->notifier);
	platform_device_unregister(gate->supplier);
	gate->supplier = NULL;
}

static void eb5_open_gate(struct work_struct *work)
{
	struct eb5_bind_gate *gate = container_of(to_delayed_work(work),
						struct eb5_bind_gate, work);
	int ret;

	if (current_is_async()) {
		dev_err(gate->owner, "NETGATE: refusing to open from async probe context\n");
		return;
	}
	if (!eb5_host_is_bound()) {
		if (time_before(jiffies, gate->deadline)) {
			schedule_delayed_work(&gate->work, msecs_to_jiffies(100));
			return;
		}
		/* Unregistering the supplier releases links instead of stranding NICs. */
		dev_err(gate->owner, "NETGATE: host timeout; releasing managed links\n");
		eb5_drop_supplier(gate);
		return;
	}

	dev_info(gate->owner, "NETGATE: native host bound; opening supplier async=0 seen=%lx\n",
		 READ_ONCE(gate->seen));
	WRITE_ONCE(gate->ready, true);
	/* Synchronous attach, with no host/device/notifier lock held here. */
	ret = device_attach(&gate->supplier->dev);
	if (ret != 1) {
		dev_err(gate->owner, "NETGATE: supplier attach failed: %d\n", ret);
		if (time_before(jiffies, gate->deadline))
			schedule_delayed_work(&gate->work, msecs_to_jiffies(100));
		else
			eb5_drop_supplier(gate);
	}
}

static int eb5_ready_probe(struct platform_device *pdev)
{
	struct eb5_bind_gate **data = dev_get_platdata(&pdev->dev);
	struct eb5_bind_gate *gate;

	/* drvdata is cleared after a deferred probe; platform data survives it. */
	if (!data || !*data)
		return -EINVAL;
	gate = *data;
	return READ_ONCE(gate->ready) ? 0 : -EPROBE_DEFER;
}

static struct platform_driver eb5_ready_driver = {
	.probe = eb5_ready_probe,
	.driver = {
		.name = EB5_GATE_NAME,
		.suppress_bind_attrs = true,
		.probe_type = PROBE_FORCE_SYNCHRONOUS,
	},
};

int eb5_bind_gate_driver_register(void)
{
	return platform_driver_register(&eb5_ready_driver);
}

void eb5_bind_gate_driver_unregister(void)
{
	platform_driver_unregister(&eb5_ready_driver);
}

int eb5_bind_gate_create(struct device *dev, struct eb5_bind_gate **result)
{
	struct eb5_bind_gate *gate;
	struct pci_dev *existing;
	int ret, bus;

	/* This is a boot-time policy, not a request to unbind an active NIC. */
	for (bus = 4; bus <= 5; bus++) {
		existing = pci_get_domain_bus_and_slot(1, bus, PCI_DEVFN(0, 0));
		if (existing) {
			pci_dev_put(existing);
			return dev_err_probe(dev, -EBUSY, "NETGATE: endpoints already exist\n");
		}
	}
	gate = devm_kzalloc(dev, sizeof(*gate), GFP_KERNEL);
	if (!gate)
		return -ENOMEM;
	gate->owner = dev;
	INIT_DELAYED_WORK(&gate->work, eb5_open_gate);
	gate->supplier = platform_device_alloc(EB5_GATE_NAME, PLATFORM_DEVID_AUTO);
	if (!gate->supplier)
		return -ENOMEM;
	gate->supplier->dev.parent = dev;
	ret = platform_device_add_data(gate->supplier, &gate, sizeof(gate));
	if (ret) {
		platform_device_put(gate->supplier);
		return ret;
	}
	ret = platform_device_add(gate->supplier);
	if (ret) {
		platform_device_put(gate->supplier);
		return ret;
	}
	gate->notifier.notifier_call = eb5_pci_notify;
	ret = bus_register_notifier(&pci_bus_type, &gate->notifier);
	if (ret) {
		platform_device_unregister(gate->supplier);
		return ret;
	}
	*result = gate;
	return 0;
}

void eb5_bind_gate_start(struct eb5_bind_gate *gate)
{
	gate->deadline = jiffies + msecs_to_jiffies(EB5_GATE_TIMEOUT_MS);
	schedule_delayed_work(&gate->work, msecs_to_jiffies(100));
}

void eb5_bind_gate_destroy(void *data)
{
	struct eb5_bind_gate *gate = data;

	/* The worker owns supplier teardown on timeout; wait for it first. */
	cancel_delayed_work_sync(&gate->work);
	if (gate->supplier)
		eb5_drop_supplier(gate);
}
