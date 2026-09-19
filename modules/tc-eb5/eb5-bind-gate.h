/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef EB5_BIND_GATE_H
#define EB5_BIND_GATE_H

struct device;
struct eb5_bind_gate;

int eb5_bind_gate_driver_register(void);
void eb5_bind_gate_driver_unregister(void);
int eb5_bind_gate_create(struct device *dev, struct eb5_bind_gate **result);
void eb5_bind_gate_start(struct eb5_bind_gate *gate);
void eb5_bind_gate_destroy(void *data);

#endif
