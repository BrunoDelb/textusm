import Dexie from "dexie";
import * as uuid from "uuid/v4";
import { Diagram, DiagramItem } from "./model";
import { ElmApp } from "./elm";

const db = new Dexie("textusm");
const svg2base64 = (id: string) => {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", `0 0 1280 960`);
    svg.setAttribute("width", "320");
    svg.setAttribute("height", "240");
    svg.setAttribute("style", "background-color: #F5F5F6;");
    const elm = document.querySelector(`#${id}`);

    if (elm) {
        svg.innerHTML = elm.innerHTML;
    }

    return `data:image/svg+xml;base64,${window.btoa(
        unescape(encodeURIComponent(new XMLSerializer().serializeToString(svg)))
    )}`;
};

db.version(1).stores({
    diagrams: "++id,title,text,thumbnail,diagramPath,createdAt,updatedAt",
});

db.version(2)
    .stores({
        diagrams:
            "++id,title,text,thumbnail,diagram,isBookmark,createdAt,updatedAt",
    })
    .upgrade((trans) => {
        //@ts-ignore
        return trans.diagrams.toCollection().modify((diagram) => {
            diagram.diagram = diagram.diagramPath;
            diagram.isBookmark = false;
            delete diagram.diagramPath;
        });
    });

export const initDB = (app: ElmApp) => {
    app.ports.saveDiagram.subscribe(
        async ({
            id,
            title,
            text,
            diagram,
            isPublic,
            isBookmark,
            isRemote,
        }: Diagram) => {
            const thumbnail = svg2base64("usm");
            const createdAt = new Date().getTime();
            const diagramItem: DiagramItem = {
                title,
                text,
                thumbnail,
                diagram,
                isPublic,
                isBookmark,
                createdAt,
                updatedAt: createdAt,
            };

            if (isRemote) {
                app.ports.saveToRemote.send(
                    JSON.stringify({
                        isRemote: true,
                        isBookmark: isBookmark,
                        id,
                        isPublic,
                        ...diagramItem,
                    })
                );
                if (id) {
                    // @ts-ignore
                    await db.diagrams.delete(id);
                }
            } else {
                const newId = id ? id : uuid();
                // @ts-ignore
                await db.diagrams.put({ id: newId, ...diagramItem });
                app.ports.saveToLocalCompleted.send(
                    JSON.stringify({
                        isRemote: false,
                        isBookmark: isBookmark,
                        id: newId,
                        isPublic,
                        ...diagramItem,
                    })
                );
            }
        }
    );

    app.ports.removeDiagrams.subscribe(async (diagram: Diagram) => {
        const { id, title, isRemote } = diagram;
        if (
            window.confirm(
                `Are you sure you want to delete "${title}" diagram?`
            )
        ) {
            if (isRemote) {
                app.ports.removeRemoteDiagram.send(JSON.stringify(diagram));
            } else {
                // @ts-ignore
                await db.diagrams.delete(id);
                app.ports.removedDiagram.send([JSON.stringify(diagram), true]);
            }
        }
    });

    app.ports.getDiagrams.subscribe(async () => {
        // @ts-ignore
        const diagrams = await db.diagrams
            .orderBy("updatedAt")
            .reverse()
            .toArray();
        app.ports.gotLocalDiagramJson.send(
            JSON.stringify(
                diagrams.map((d: Diagram) => ({
                    isPublic: false,
                    isBookmark: false,
                    isRemote: false,
                    createdAt: new Date(),
                    updatedAt: new Date(),
                    ...d,
                }))
            )
        );
    });
};
