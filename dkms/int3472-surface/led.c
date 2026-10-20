// SPDX-License-Identifier: GPL-2.0
/* Author: Hans de Goede <hdegoede@redhat.com> */

#include <linux/acpi.h>
#include <linux/gpio/consumer.h>
#include <linux/leds.h>
#include <linux/platform_data/x86/int3472.h>
#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 1, 0)
/* Linux 7.1 generalized the privacy LED to an array of LEDs. */
static int int3472_led_set(struct led_classdev *led_cdev, enum led_brightness brightness)
{
	struct int3472_led *led = container_of(led_cdev, struct int3472_led, classdev);

	gpiod_set_value_cansleep(led->gpio, brightness);
	return 0;
}

int skl_int3472_register_led(struct int3472_discrete_device *int3472, struct gpio_desc *gpio,
			     const char *con_id)
{
	struct int3472_led *led;
	char *p;
	int ret;

	if (int3472->n_leds >= INT3472_MAX_LEDS)
		return -ENOSPC;

	led = &int3472->leds[int3472->n_leds];
	led->gpio = gpio;

	/* Generate the name, replacing the ':' in the ACPI devname with '_' */
	snprintf(led->name, sizeof(led->name),
		 "%s::%s_led", acpi_dev_name(int3472->sensor), con_id);
	p = strchr(led->name, ':');
	if (p)
		*p = '_';

	led->classdev.name = led->name;
	led->classdev.max_brightness = 1;
	led->classdev.brightness_set_blocking = int3472_led_set;

	ret = led_classdev_register(int3472->dev, &led->classdev);
	if (ret)
		return ret;

	led->lookup.provider = led->name;
	led->lookup.dev_id = int3472->sensor_name;
	led->lookup.con_id = con_id;
	led_add_lookup(&led->lookup);

	int3472->n_leds++;
	return 0;
}

void skl_int3472_unregister_leds(struct int3472_discrete_device *int3472)
{
	for (unsigned int i = 0; i < int3472->n_leds; i++) {
		struct int3472_led *led = &int3472->leds[i];

		led_remove_lookup(&led->lookup);
		led_classdev_unregister(&led->classdev);
		gpiod_put(led->gpio);
	}
}
#else
static int int3472_pled_set(struct led_classdev *led_cdev,
				     enum led_brightness brightness)
{
	struct int3472_discrete_device *int3472 =
		container_of(led_cdev, struct int3472_discrete_device, pled.classdev);

	gpiod_set_value_cansleep(int3472->pled.gpio, brightness);
	return 0;
}

int skl_int3472_register_pled(struct int3472_discrete_device *int3472, struct gpio_desc *gpio)
{
	char *p;
	int ret;

	if (int3472->pled.classdev.dev)
		return -EBUSY;

	int3472->pled.gpio = gpio;

	/* Generate the name, replacing the ':' in the ACPI devname with '_' */
	snprintf(int3472->pled.name, sizeof(int3472->pled.name),
		 "%s::privacy_led", acpi_dev_name(int3472->sensor));
	p = strchr(int3472->pled.name, ':');
	if (p)
		*p = '_';

	int3472->pled.classdev.name = int3472->pled.name;
	int3472->pled.classdev.max_brightness = 1;
	int3472->pled.classdev.brightness_set_blocking = int3472_pled_set;

	ret = led_classdev_register(int3472->dev, &int3472->pled.classdev);
	if (ret)
		return ret;

	int3472->pled.lookup.provider = int3472->pled.name;
	int3472->pled.lookup.dev_id = int3472->sensor_name;
	int3472->pled.lookup.con_id = "privacy";
	led_add_lookup(&int3472->pled.lookup);

	return 0;
}

void skl_int3472_unregister_pled(struct int3472_discrete_device *int3472)
{
	if (IS_ERR_OR_NULL(int3472->pled.classdev.dev))
		return;

	led_remove_lookup(&int3472->pled.lookup);
	led_classdev_unregister(&int3472->pled.classdev);
	gpiod_put(int3472->pled.gpio);
}
#endif
