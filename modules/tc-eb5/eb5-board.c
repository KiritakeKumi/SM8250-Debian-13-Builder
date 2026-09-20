// SPDX-License-Identifier: GPL-2.0-only
/*
 * TC-EB5 board GPIO sequencer and PERST provider for the stock PCIe driver.
 *
 * From Evsio0n/tc-eb5-oot v0.2.1:
 *   https://github.com/evsio0n/tc-eb5-oot
 *   (modules/eb5-board.c)
 *
 * Local change vs upstream: gpio_chip::set returns int, matching the gpiolib
 * change in Linux 6.15 ("gpiolib: allow set() to fail").
 *
 * See CREDITS.md for the full attribution and the upstream test results.
 */
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/gpio/driver.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/pci.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>
#include <linux/workqueue.h>

#include <dt-bindings/gpio/gpio.h>

#include "eb5-bind-gate.h"

enum eb5_gpio {
	EB5_CTRL_88,
	EB5_CTRL_89,
	EB5_CTRL_121,
	EB5_CTRL_127,
	EB5_CTRL_126,
	EB5_NUM_CONTROLS,
	EB5_PERST = EB5_NUM_CONTROLS,
	EB5_NUM_GPIOS,
};

static const unsigned int eb5_pins[EB5_NUM_GPIOS] = {
	[EB5_CTRL_88] = 88,
	[EB5_CTRL_89] = 89,
	[EB5_CTRL_121] = 121,
	[EB5_CTRL_127] = 127,
	[EB5_CTRL_126] = 126,
	[EB5_PERST] = 82,
};

struct eb5_step {
	enum eb5_gpio gpio;
	int raw_level;
	unsigned int hold_ms;
};

/* Physical levels verified by vendor disassembly and Boot176/177 board tests. */
static const struct eb5_step eb5_sequence[] = {
	{ EB5_PERST,    1,  100 },
	{ EB5_PERST,    0,  200 },
	{ EB5_CTRL_88,  0,   10 },
	{ EB5_CTRL_88,  1,   10 },
	{ EB5_CTRL_89,  0,   10 },
	{ EB5_CTRL_89,  1,   10 },
	{ EB5_CTRL_121, 1, 5000 },
	{ EB5_CTRL_127, 1,    0 },
	{ EB5_CTRL_126, 1,  120 },
};

struct eb5_pcie {
	struct device *dev;
	struct gpio_desc *gpios[EB5_NUM_GPIOS];
	struct gpio_chip chip;
	struct eb5_bind_gate *bind_gate;
	/* Serialize the physical PERST transition and its settling delays. */
	struct mutex lock;
	struct delayed_work diagnostics;
	unsigned int diagnostic_attempts;
	unsigned int diagnostic_samples;
};

static int eb5_check_gpio(struct device *dev, const char *property,
			  unsigned int index, unsigned int pin, unsigned int flags)
{
	struct of_phandle_args args;
	bool valid;
	int ret;

	ret = of_parse_phandle_with_args(dev->of_node, property, "#gpio-cells", index, &args);
	if (ret)
		return dev_err_probe(dev, ret, "Cannot parse %s[%u]\n", property, index);
	valid = of_device_is_compatible(args.np, "qcom,sm8250-pinctrl") &&
		args.args_count == 2 && args.args[0] == pin && args.args[1] == flags;
	of_node_put(args.np);
	if (!valid)
		return dev_err_probe(dev, -EINVAL, "Unexpected %s[%u]\n", property, index);
	return 0;
}

static int eb5_check_consumer(struct device *dev)
{
	struct device_node *pcie;
	struct of_phandle_args args;
	u32 cells;
	bool valid;
	int ret;

	if (!of_machine_is_compatible("thundercomm,eb5") ||
	    !of_property_read_bool(dev->of_node, "gpio-controller") ||
	    of_property_read_u32(dev->of_node, "#gpio-cells", &cells) || cells != 2)
		return -EINVAL;
	pcie = of_find_node_by_path("/soc@0/pcie@1c08000");
	if (!pcie)
		return -ENODEV;
	valid = of_device_is_available(pcie) &&
		of_device_is_compatible(pcie, "qcom,pcie-sm8250");
	ret = of_parse_phandle_with_args(pcie, "perst-gpios", "#gpio-cells", 0, &args);
	of_node_put(pcie);
	if (ret)
		return ret;
	valid = valid && args.np == dev->of_node && args.args_count == 2 &&
		args.args[0] == 0 && args.args[1] == GPIO_ACTIVE_LOW;
	of_node_put(args.np);
	return valid ? 0 : -EINVAL;
}

static int eb5_get_gpios(struct eb5_pcie *eb5)
{
	struct device *dev = eb5->dev;
	struct gpio_descs *controls;
	unsigned int i;
	int ret;

	ret = eb5_check_gpio(dev, "reset-gpios", 0, 82, GPIO_ACTIVE_LOW);
	if (ret)
		return ret;
	ret = gpiod_count(dev, "control");
	if (ret < 0)
		return ret;
	if (ret != EB5_NUM_CONTROLS)
		return -EINVAL;
	for (i = 0; i < EB5_NUM_CONTROLS; i++) {
		ret = eb5_check_gpio(dev, "control-gpios", i, eb5_pins[i], GPIO_ACTIVE_HIGH);
		if (ret)
			return ret;
	}

	/* No output changes until all descriptors are acquired and validated. */
	eb5->gpios[EB5_PERST] = devm_gpiod_get(dev, "reset", GPIOD_ASIS);
	if (IS_ERR(eb5->gpios[EB5_PERST]))
		return PTR_ERR(eb5->gpios[EB5_PERST]);
	controls = devm_gpiod_get_array(dev, "control", GPIOD_ASIS);
	if (IS_ERR(controls))
		return PTR_ERR(controls);
	if (controls->ndescs != EB5_NUM_CONTROLS)
		return -EINVAL;
	for (i = 0; i < EB5_NUM_CONTROLS; i++)
		eb5->gpios[i] = controls->desc[i];
	return 0;
}

static int eb5_drive_step(struct eb5_pcie *eb5, const struct eb5_step *step)
{
	struct gpio_desc *gpio = eb5->gpios[step->gpio];
	int ret, direction, raw;

	ret = gpiod_direction_output_raw(gpio, step->raw_level);
	if (ret)
		return ret;
	if (step->hold_ms)
		msleep(step->hold_ms);
	direction = gpiod_get_direction(gpio);
	raw = gpiod_get_raw_value_cansleep(gpio);
	dev_info(eb5->dev, "EB5 ASM2806: GPIO%u requested=%d dir=%d raw=%d hold_ms=%u\n",
		 eb5_pins[step->gpio], step->raw_level, direction, raw, step->hold_ms);
	if (direction < 0)
		return direction;
	if (raw < 0)
		return raw;
	return direction == 0 && raw == step->raw_level ? 0 : -EIO;
}

static int eb5_prepare(struct eb5_pcie *eb5)
{
	unsigned int i;
	int ret;

	/* Reproduce the stock host's initial asserted PERST before the waveform. */
	ret = gpiod_direction_output_raw(eb5->gpios[EB5_PERST], 0);
	if (ret)
		return ret;
	dev_info(eb5->dev, "EB5 ASM2806: verified TLMM controls; GPIO141 remains wake input\n");
	for (i = 0; i < ARRAY_SIZE(eb5_sequence); i++) {
		ret = eb5_drive_step(eb5, &eb5_sequence[i]);
		if (ret) {
			gpiod_set_raw_value_cansleep(eb5->gpios[EB5_PERST], 0);
			return ret;
		}
	}
	dev_info(eb5->dev, "EB5 ASM2806: sequence complete; PERST held low for PHY init\n");
	return 0;
}

/* gpio_chip callbacks receive physical values: consumer ACTIVE_LOW is applied. */
static void eb5_set_perst_locked(struct eb5_pcie *eb5, int raw)
{
	if (raw) {
		dev_info(eb5->dev, "EB5 ASM2806: pre-PERST-release settle 10 ms\n");
		usleep_range(10000, 10005);
	}
	gpiod_set_raw_value_cansleep(eb5->gpios[EB5_PERST], raw);
	if (raw) {
		dev_info(eb5->dev, "EB5 ASM2806: post-PERST settle 200 ms (before LTSSM)\n");
		msleep(200);
	}
}

/* gpio_chip::set returns int since Linux 6.15 (commit "gpiolib: allow set() to fail"). */
static int eb5_set(struct gpio_chip *chip, unsigned int offset, int value)
{
	struct eb5_pcie *eb5 = gpiochip_get_data(chip);

	mutex_lock(&eb5->lock);
	eb5_set_perst_locked(eb5, !!value);
	mutex_unlock(&eb5->lock);

	return 0;
}

static int eb5_direction_output(struct gpio_chip *chip, unsigned int offset, int value)
{
	struct eb5_pcie *eb5 = gpiochip_get_data(chip);
	int direction;

	/* Real PERST was configured and checked before exposing this chip. */
	eb5_set(chip, offset, value);
	direction = gpiod_get_direction(eb5->gpios[EB5_PERST]);
	return direction < 0 ? direction : direction == 0 ? 0 : -EIO;
}

static int eb5_get(struct gpio_chip *chip, unsigned int offset)
{
	struct eb5_pcie *eb5 = gpiochip_get_data(chip);

	return gpiod_get_raw_value_cansleep(eb5->gpios[EB5_PERST]);
}

static int eb5_get_direction(struct gpio_chip *chip, unsigned int offset)
{
	struct eb5_pcie *eb5 = gpiochip_get_data(chip);

	return gpiod_get_direction(eb5->gpios[EB5_PERST]);
}

static void eb5_diagnostics(struct work_struct *work)
{
	struct eb5_pcie *eb5 = container_of(to_delayed_work(work), struct eb5_pcie, diagnostics);
	struct device *host;
	struct platform_device *pdev;
	struct pci_dev *root;
	struct resource *parf_res, *elbi_res;
	void __iomem *parf, *elbi;
	u32 debug0, debug1;
	int ret;

	if (++eb5->diagnostic_attempts > 60) {
		dev_warn(eb5->dev, "PCIe1 diagnostics timed out waiting for native host\n");
		return;
	}
	host = bus_find_device_by_name(&platform_bus_type, NULL, "1c08000.pcie");
	if (!host)
		goto retry;
	if (!device_trylock(host)) {
		put_device(host);
		goto retry;
	}
	if (!host->driver || strcmp(host->driver->name, "qcom-pcie"))
		goto unlock;
	/* Read-only observation: do not wake an idle/suspended controller. */
	ret = pm_runtime_get_if_in_use(host);
	if (ret <= 0)
		goto unlock;
	pdev = to_platform_device(host);
	parf_res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "parf");
	elbi_res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "elbi");
	if (!parf_res || !elbi_res || parf_res->start != 0x01c08000 ||
	    resource_size(parf_res) < 0x1b4 || resource_size(elbi_res) < 0xc)
		goto put_pm;
	root = pci_get_domain_bus_and_slot(1, 0, PCI_DEVFN(0, 0));
	if (!root)
		goto put_pm;
	ret = pci_read_config_dword(root, 0x728, &debug0);
	ret |= pci_read_config_dword(root, 0x72c, &debug1);
	pci_dev_put(root);
	if (ret)
		goto put_pm;
	/* Non-owning read-only aliases; the native driver owns these resources. */
	parf = ioremap(parf_res->start, resource_size(parf_res));
	elbi = ioremap(elbi_res->start, resource_size(elbi_res));
	if (parf && elbi) {
		dev_info(eb5->dev,
			 "ASM2806 POSTLINK k=%u LTSSM=0x%02x DBG0=0x%08x DBG1=0x%08x\n",
			 eb5->diagnostic_samples, debug0 & 0x1f, debug0, debug1);
		dev_info(eb5->dev,
			 "ASM2806 STAT k=%u ELBI[0/4/8]=0x%08x/0x%08x/0x%08x PARF_LTSSM=0x%08x\n",
			 eb5->diagnostic_samples, readl(elbi), readl(elbi + 4),
			 readl(elbi + 8), readl(parf + 0x1b0));
		eb5->diagnostic_samples++;
	}
	if (elbi)
		iounmap(elbi);
	if (parf)
		iounmap(parf);
put_pm:
	pm_runtime_put(host);
unlock:
	device_unlock(host);
	put_device(host);
retry:
	if (eb5->diagnostic_samples < 6)
		schedule_delayed_work(&eb5->diagnostics, msecs_to_jiffies(500));
}

static void eb5_cancel_diagnostics(void *data)
{
	struct eb5_pcie *eb5 = data;

	cancel_delayed_work_sync(&eb5->diagnostics);
}

static int eb5_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct eb5_pcie *eb5;
	int ret;

	ret = eb5_check_consumer(dev);
	if (ret)
		return dev_err_probe(dev, ret, "Refusing unsupported board/PCIe consumer\n");
	eb5 = devm_kzalloc(dev, sizeof(*eb5), GFP_KERNEL);
	if (!eb5)
		return -ENOMEM;
	eb5->dev = dev;
	mutex_init(&eb5->lock);
	ret = eb5_get_gpios(eb5);
	if (ret)
		return dev_err_probe(dev, ret, "Board GPIO resources unavailable\n");
	ret = eb5_prepare(eb5);
	if (ret)
		return dev_err_probe(dev, ret, "Board sequence failed; provider not exposed\n");
	/* The gate must see endpoint ADD events before PCIe can obtain PERST. */
	ret = eb5_bind_gate_create(dev, &eb5->bind_gate);
	if (ret)
		return ret;
	eb5->chip.label = "tc-eb5-pcie-perst";
	eb5->chip.parent = dev;
	eb5->chip.fwnode = dev_fwnode(dev);
	eb5->chip.owner = THIS_MODULE;
	eb5->chip.base = -1;
	eb5->chip.ngpio = 1;
	eb5->chip.can_sleep = true;
	eb5->chip.get = eb5_get;
	eb5->chip.set = eb5_set;
	eb5->chip.get_direction = eb5_get_direction;
	eb5->chip.direction_output = eb5_direction_output;
	ret = devm_gpiochip_add_data(dev, &eb5->chip, eb5);
	if (ret) {
		eb5_bind_gate_destroy(eb5->bind_gate);
		/* Do not defer after registering the gate's child device. */
		if (ret == -EPROBE_DEFER)
			ret = -EINVAL;
		return ret;
	}
	ret = devm_add_action_or_reset(dev, eb5_bind_gate_destroy, eb5->bind_gate);
	if (ret)
		return ret;
	INIT_DELAYED_WORK(&eb5->diagnostics, eb5_diagnostics);
	ret = devm_add_action_or_reset(dev, eb5_cancel_diagnostics, eb5);
	if (ret)
		return ret;
	schedule_delayed_work(&eb5->diagnostics, msecs_to_jiffies(1000));
	eb5_bind_gate_start(eb5->bind_gate);
	dev_info(dev, "PERST provider ready for the unmodified native PCIe driver\n");
	return 0;
}

static const struct of_device_id eb5_match[] = {
	{ .compatible = "thundercomm,tc-eb5-pcie-sequencer" },
	{ }
};
MODULE_DEVICE_TABLE(of, eb5_match);

static struct platform_driver eb5_driver = {
	.probe = eb5_probe,
	.driver = {
		.name = "tc-eb5-pcie-helper",
		.of_match_table = eb5_match,
		.suppress_bind_attrs = true,
	},
};

static int __init eb5_init(void)
{
	int ret;

	ret = eb5_bind_gate_driver_register();
	if (ret)
		return ret;
	ret = platform_driver_register(&eb5_driver);
	if (ret)
		eb5_bind_gate_driver_unregister();
	return ret;
}
module_init(eb5_init);

static void __exit eb5_exit(void)
{
	platform_driver_unregister(&eb5_driver);
	eb5_bind_gate_driver_unregister();
}
module_exit(eb5_exit);

MODULE_DESCRIPTION("TC-EB5 external board sequencer and GPIO PERST provider");
MODULE_LICENSE("GPL");
MODULE_VERSION("0.2.1");
