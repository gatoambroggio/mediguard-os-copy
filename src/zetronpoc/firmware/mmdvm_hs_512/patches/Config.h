/*
 *   Copyright (C) 2017,2018,2019,2020 by Andy Uribe CA6JAU
 *
 *   This program is free software; you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation; either version 2 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with this program; if not, write to the Free Software
 *   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#if !defined(CONFIG_H)
#define  CONFIG_H

// Nano hotSPOT (BI7JTA) - Jumbospot clone
// Single ADF7021, SIMPLEX (NO duplex — DUPLEX es para placas con 2x ADF7021)
#define NANO_HOTSPOT

// Enable ADF7021 support:
#define ENABLE_ADF7021

// SIMPLEX: single ADF7021. NO definir DUPLEX (eso es para dual ADF7021).
// BIDIR_DATA_PIN ya viene habilitado por defecto en Globals.h (Standard TX/RX
// Data Interface del ADF7021, necesario para scan mode).

// TCXO 14.7456 MHz (confirmado del string de firmware: MMDVM_HS-v1.6.0 14.7456MHz)
#define ADF7021_14_7456

// AGC automatic, default settings:
#define AD7021_GAIN_AUTO

// Host communication: UART (Jumbospot conectado via USB-TTL serial)
#define STM32_USART1_HOST

// I2C host address:
#define I2C_ADDR 0x22

// Enable mode detection:
#define ENABLE_SCAN_MODE

// Send RSSI value:
#define SEND_RSSI_DATA

// Nextion LCD serial port repeater on USART2
#define SERIAL_REPEATER
#define SERIAL_REPEATER_BAUD 9600

// Enable P25 Wide modulation:
// #define ENABLE_P25_WIDE

// Engage a constant or descreet Service LED mode once repeater is running 
// #define CONSTANT_SRV_LED
// #define DISCREET_SRV_LED

// Use the YSF and P25 LEDs for NXDN
// #define USE_ALTERNATE_NXDN_LEDS

// Use the D-Star and P25 LEDs for M17
// #define USE_ALTERNATE_M17_LEDS

// Use the D-Star and DMR LEDs for POCSAG
// #define USE_ALTERNATE_POCSAG_LEDS

// Enable for RPi 3B+, USB mode
// #define LONG_USB_RESET

// Enable modem debug messages
#define ENABLE_DEBUG

// Disable frequency bands check
// #define DISABLE_FREQ_CHECK

// Disable frequency restrictions (satellite, ISS, etc)
// #define DISABLE_FREQ_BAN

// Enable UDID feature
// #define ENABLE_UDID

#endif
