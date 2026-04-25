@testable import DemoWorkspace
import Testing

struct CalculatorTests {
    @Test
    func addReturnsSum() {
        #expect(Calculator.add(2, 3) == 5)
    }

    @Test
    func multiplyReturnsProduct() {
        #expect(Calculator.multiply(4, 5) == 20)
    }
}
