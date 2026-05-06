import fastify from "fastify";
import { describe, expect, it } from "vitest";
import { type Fastify } from "../types";
import { legalRoutes } from "./legalRoutes";

describe("legalRoutes", () => {
    it("serves the HarmonyOS privacy policy as public HTML", async () => {
        const app = fastify();
        legalRoutes(app as unknown as Fastify);

        const response = await app.inject({
            method: "GET",
            url: "/privacy/harmonyos"
        });

        expect(response.statusCode).toBe(200);
        expect(response.headers["content-type"]).toContain("text/html; charset=utf-8");
        expect(response.body).toContain("Happy HarmonyOS 隐私政策");
        expect(response.body).toContain("应用包名：com.ex3ndr.happy");
        expect(response.body).toContain("运营者：滕翼");
        expect(response.body).toContain("联系邮箱");
        expect(response.body).not.toContain("请填写");
    });

    it("serves an html-suffixed alias", async () => {
        const app = fastify();
        legalRoutes(app as unknown as Fastify);

        const response = await app.inject({
            method: "GET",
            url: "/privacy/harmonyos.html"
        });

        expect(response.statusCode).toBe(200);
        expect(response.body).toContain("Happy HarmonyOS 隐私政策");
    });
});
