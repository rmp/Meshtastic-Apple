//
//  Int.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 4/25/23.
//

extension Int {

	func numberOfDigits() -> Int {
		if abs(self) < 10 {
			return 1
		} else {
			return 1 + (self/10).numberOfDigits()
		}
	}
}
