package com.demo;

import java.util.List;
import com.demo.util.Helper;
import com.demo.util.Missing;

/** Demo entry point wiring the greeter to a helper. */
public class App {
    public static void main(String[] args) {
        List<String> names = List.of("world");
        for (String n : names) {
            try {
                System.out.println(Helper.greet(n));
                Missing.tag(n);
            } catch (RuntimeException e) {
            }
        }
    }
}
